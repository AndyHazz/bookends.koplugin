-- Dev-box test runner for bookends_tokens.lua conditional parsing.
-- Runs pure-Lua (no KOReader) by stubbing the modules bookends_tokens requires.
-- Usage: cd into the plugin dir, then `lua _test_conditionals.lua`.
-- Exits non-zero on failure; no external dependencies.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
}
package.loaded["datetime"] = {
    secondsToClockDuration = function() return "" end,
}
package.loaded["bookends_overlay_widget"] = { BAR_PLACEHOLDER = "\x00BAR\x00" }

-- G_reader_settings is a global in KOReader; stub it so module load succeeds.
_G.G_reader_settings = setmetatable({}, {
    __index = function() return function() return false end end,
})

local Tokens = dofile("bookends_tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        pass = pass + 1
    else
        fail = fail + 1
        io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
    end
end

local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "")
            .. " expected=" .. string.format("%q", tostring(expected))
            .. " got="      .. string.format("%q", tostring(actual)), 2)
    end
end

-- ============================================================================
-- Baseline: tests that must pass against the CURRENT (pre-change) parser.
-- These lock in existing behaviour so the upcoming rewrite can't regress it.
-- ============================================================================

-- Flat truthy predicate
test("flat truthy: state value 'yes' is true", function()
    local r = Tokens._processConditionals("[if:charging=yes]+[/if]", { charging = "yes" })
    eq(r, "+")
end)

test("flat truthy: state value 'no' is false", function()
    local r = Tokens._processConditionals("[if:charging=yes]+[/if]", { charging = "no" })
    eq(r, "")
end)

-- Bare-key truthy check (no operator)
test("bare key: empty string is falsy", function()
    local r = Tokens._processConditionals("[if:x]YES[/if]", { x = "" })
    eq(r, "")
end)

test("bare key: non-empty string is truthy", function()
    local r = Tokens._processConditionals("[if:x]YES[/if]", { x = "hello" })
    eq(r, "YES")
end)

-- Numeric comparison
test("batt<20 when batt=15 → true", function()
    local r = Tokens._processConditionals("[if:batt<20]LOW[/if]", { batt = 15 })
    eq(r, "LOW")
end)

test("batt<20 when batt=85 → false", function()
    local r = Tokens._processConditionals("[if:batt<20]LOW[/if]", { batt = 85 })
    eq(r, "")
end)

-- HH:MM numeric coercion
test("time>=18:30 when time=1110 (18:30) → true", function()
    local r = Tokens._processConditionals("[if:time>18:00]evening[/if]", { time = 18*60 + 30 })
    eq(r, "evening")
end)

-- [else] branch
test("[else] branch when predicate false", function()
    local r = Tokens._processConditionals("[if:a=1]A[else]B[/if]", { a = 2 })
    eq(r, "B")
end)

test("[else] branch when predicate true → takes if-part", function()
    local r = Tokens._processConditionals("[if:a=1]A[else]B[/if]", { a = 1 })
    eq(r, "A")
end)

-- Multiple sibling blocks
test("two sibling blocks both resolve", function()
    local r = Tokens._processConditionals("[if:a=1]A[/if]-[if:b=2]B[/if]", { a = 1, b = 2 })
    eq(r, "A-B")
end)

-- No conditional content left alone
test("string with no conditionals passes through", function()
    local r = Tokens._processConditionals("plain text %T %A", {})
    eq(r, "plain text %T %A")
end)

-- Unknown key
test("unknown key evaluates to false", function()
    local r = Tokens._processConditionals("[if:xyzzy=yes]X[/if]", {})
    eq(r, "")
end)


-- ----------------------------------------------------------------------------
-- Expression evaluator (new) — tests exercising Tokens._evaluateExpression
-- directly, before it is wired into processConditionals.
-- ----------------------------------------------------------------------------

local function E(cond, state) return Tokens._evaluateExpression(cond, state or {}) end

test("evaluator: single atom true", function() eq(E("a=1", {a=1}), true)  end)
test("evaluator: single atom false",function() eq(E("a=1", {a=2}), false) end)

test("evaluator: AND both true",    function() eq(E("a=1 and b=2", {a=1,b=2}), true)  end)
test("evaluator: AND one false",    function() eq(E("a=1 and b=2", {a=1,b=3}), false) end)

test("evaluator: OR one true",      function() eq(E("a=1 or b=2",  {a=1,b=3}), true)  end)
test("evaluator: OR both false",    function() eq(E("a=1 or b=2",  {a=0,b=3}), false) end)

test("evaluator: NOT inverts true",  function() eq(E("not a=1", {a=1}), false) end)
test("evaluator: NOT inverts false", function() eq(E("not a=1", {a=2}), true)  end)

test("evaluator: parens group",      function()
    eq(E("(a=1 or b=2) and c=3", {a=1, b=0, c=3}), true)
    eq(E("(a=1 or b=2) and c=3", {a=0, b=2, c=3}), true)
    eq(E("(a=1 or b=2) and c=3", {a=0, b=0, c=3}), false)
    eq(E("(a=1 or b=2) and c=3", {a=1, b=0, c=4}), false)
end)

test("evaluator: precedence — and binds tighter than or", function()
    -- a=1 or b=2 and c=3  ≡  a=1 or (b=2 and c=3)
    eq(E("a=1 or b=2 and c=3", {a=1, b=0, c=0}), true)   -- a alone
    eq(E("a=1 or b=2 and c=3", {a=0, b=2, c=3}), true)   -- b and c together
    eq(E("a=1 or b=2 and c=3", {a=0, b=2, c=4}), false)  -- c fails so b alone insufficient
end)

test("evaluator: precedence — not binds tighter than and", function()
    -- not a=1 and b=2  ≡  (not a=1) and b=2
    eq(E("not a=1 and b=2", {a=2, b=2}), true)
    eq(E("not a=1 and b=2", {a=1, b=2}), false)
end)

-- Bare atom (truthy form) — existing evaluateCondition fallback must still work
test("evaluator: bare-key truthy (non-empty string)", function()
    eq(E("title", {title = "Foo"}), true)
end)

test("evaluator: bare-key truthy (empty string)", function()
    eq(E("title", {title = ""}), false)
end)


-- ----------------------------------------------------------------------------
-- processConditionals with nesting (new) + operators end-to-end.
-- ----------------------------------------------------------------------------

local function P(fmt, state) return Tokens._processConditionals(fmt, state or {}) end

-- Nesting
test("nest: inner+outer both true", function()
    eq(P("[if:a=1][if:b=2]INNER[/if][/if]", {a=1, b=2}), "INNER")
end)

test("nest: outer true, inner false", function()
    eq(P("[if:a=1][if:b=2]INNER[/if][/if]", {a=1, b=9}), "")
end)

test("nest: outer false (inner irrelevant)", function()
    eq(P("[if:a=1][if:b=2]INNER[/if][/if]", {a=9, b=2}), "")
end)

test("nest: 3 levels, all true", function()
    eq(P("[if:a=1][if:b=2][if:c=3]X[/if][/if][/if]", {a=1,b=2,c=3}), "X")
end)

test("nest: outer has text before and after inner", function()
    eq(P("[if:a=1]X[if:b=2]Y[/if]Z[/if]", {a=1, b=2}), "XYZ")
    eq(P("[if:a=1]X[if:b=2]Y[/if]Z[/if]", {a=1, b=9}), "XZ")
end)

test("nest: [else] on outer with nested inner", function()
    eq(P("[if:a=1][if:b=2]bb[/if][else]A-else[/if]", {a=1, b=2}), "bb")
    eq(P("[if:a=1][if:b=2]bb[/if][else]A-else[/if]", {a=1, b=9}), "")
    eq(P("[if:a=1][if:b=2]bb[/if][else]A-else[/if]", {a=9, b=2}), "A-else")
end)

test("nest: [else] on inner", function()
    eq(P("[if:a=1][if:b=2]bb[else]b-else[/if][/if]", {a=1, b=2}), "bb")
    eq(P("[if:a=1][if:b=2]bb[else]b-else[/if][/if]", {a=1, b=9}), "b-else")
    eq(P("[if:a=1][if:b=2]bb[else]b-else[/if][/if]", {a=9, b=2}), "")
end)

test("nest: [else] on both inner and outer", function()
    eq(P("[if:a=1][if:b=2]bb[else]b-else[/if][else]A-else[/if]", {a=9, b=2}), "A-else")
    eq(P("[if:a=1][if:b=2]bb[else]b-else[/if][else]A-else[/if]", {a=1, b=9}), "b-else")
end)

-- Operators inside processConditionals (end-to-end)
test("ops: AND in predicate", function()
    eq(P("[if:a=1 and b=2]X[/if]", {a=1, b=2}), "X")
    eq(P("[if:a=1 and b=2]X[/if]", {a=1, b=9}), "")
end)

test("ops: OR in predicate", function()
    eq(P("[if:day=Sat or day=Sun]WE[/if]", {day="Sat"}), "WE")
    eq(P("[if:day=Sat or day=Sun]WE[/if]", {day="Mon"}), "")
end)

test("ops: NOT in predicate", function()
    eq(P("[if:not charging=yes]batt[/if]", {charging="no"}), "batt")
    eq(P("[if:not charging=yes]batt[/if]", {charging="yes"}), "")
end)

test("ops: grouping with parens", function()
    eq(P("[if:(a=1 or b=2) and c=3]X[/if]", {a=1, b=9, c=3}), "X")
    eq(P("[if:(a=1 or b=2) and c=3]X[/if]", {a=9, b=9, c=3}), "")
end)

-- Edge cases
test("edge: unbalanced opener passes through", function()
    eq(P("[if:a=1]foo", {a=1}), "[if:a=1]foo")
end)

test("edge: orphan closer passes through", function()
    eq(P("foo[/if]bar", {}), "foo[/if]bar")
end)

test("edge: empty predicate evaluates to false", function()
    eq(P("[if:]X[else]Y[/if]", {}), "Y")
end)


-- ----------------------------------------------------------------------------
-- Predicate renames — percent → book_pct, chapter → chapter_pct,
-- pages → session_pages. Tests exercise the state-table lookup via
-- processConditionals directly; buildConditionState runtime sourcing is
-- verified on-device (requires ui/doc).
-- ----------------------------------------------------------------------------

test("rename: book_pct is the new name for book percent", function()
    eq(P("[if:book_pct>50]past half[/if]", {book_pct=75}), "past half")
    eq(P("[if:book_pct>50]past half[/if]", {book_pct=25}), "")
end)

test("rename: chapter_pct is the new name for chapter percent", function()
    eq(P("[if:chapter_pct>50]x[/if]", {chap_pct=75}), "x")
end)

test("rename: session_pages is the new name for session pages read", function()
    eq(P("[if:session_pages>10]many[/if]", {session_pages=25}), "many")
    eq(P("[if:session_pages>10]many[/if]", {session_pages=5}), "")
end)

test("rename: old names (percent, pages) no longer recognised → false", function()
    eq(P("[if:percent>50]x[/if]", { percent = 75 }), "x")
    eq(P("[if:percent>50]x[/if]", {}), "")
end)

-- ----------------------------------------------------------------------------
-- New numeric predicates: chapter, chapters.
-- ----------------------------------------------------------------------------

test("new: chapters>20 true", function()
    eq(P("[if:chapters>20]long[/if]", {chap_count=25}), "long")
end)

test("new: chapters>20 false", function()
    eq(P("[if:chapters>20]long[/if]", {chap_count=15}), "")
end)

test("new: chapter=1 (first chapter)", function()
    eq(P("[if:chapter=1]intro[/if]", {chap_num=1}), "intro")
    eq(P("[if:chapter=1]intro[/if]", {chap_num=2}), "")
end)

test("new: combined chapter + chapters", function()
    eq(P("[if:chapter=1 and chapters>20]long intro[/if]", {chap_num=1, chap_count=25}), "long intro")
end)

-- ----------------------------------------------------------------------------
-- New string predicates: title, author, series, chapter_title, chapter_title_1..3
-- ----------------------------------------------------------------------------

test("string: chapter_title_2 empty falls to else", function()
    eq(P("[if:chapter_title_2]%C2[else]%C1[/if]", {chap_title_2=""}), "%C1")
end)

test("string: chapter_title_2 present takes if", function()
    eq(P("[if:chapter_title_2]%C2[else]%C1[/if]", {chap_title_2="Subchapter A"}), "%C2")
end)

test("string: not series → standalone", function()
    eq(P("[if:not series]solo[else]%S[/if]", {series=""}),       "solo")
    eq(P("[if:not series]solo[else]%S[/if]", {series="Foo #2"}), "%S")
end)

test("string: author = Anonymous", function()
    eq(P("[if:author=Anonymous]?[/if]", {author="Anonymous"}), "?")
    eq(P("[if:author=Anonymous]?[/if]", {author="Ursula K. Le Guin"}), "")
end)

test("string: quoted RHS with spaces matches", function()
    eq(P([=[[if:author="J.R.R. Tolkien"]match[/if]]=],
         {author="J.R.R. Tolkien"}), "match")
    eq(P([=[[if:author="J.R.R. Tolkien"]match[/if]]=],
         {author="Ursula K. Le Guin"}), "")
end)

test("string: quoted RHS with != and spaces", function()
    eq(P([=[[if:author!="J.R.R. Tolkien"]other[/if]]=],
         {author="Ursula K. Le Guin"}), "other")
    eq(P([=[[if:author!="J.R.R. Tolkien"]other[/if]]=],
         {author="J.R.R. Tolkien"}), "")
end)

test("string: quoted RHS composes with boolean operators", function()
    eq(P([=[[if:series="Foo Bar #2" and not chapter_title_2]hit[/if]]=],
         {series="Foo Bar #2", chap_title_2=""}), "hit")
    eq(P([=[[if:series="Foo Bar #2" and not chapter_title_2]hit[/if]]=],
         {series="Other", chap_title_2=""}), "")
end)

test("string: empty quoted RHS matches empty state", function()
    eq(P([=[[if:series=""]nope[/if]]=], {series=""}), "nope")
    eq(P([=[[if:series=""]nope[/if]]=], {series="Foo #1"}), "")
end)

test("string: quoted RHS works through legacy-alias rewrite", function()
    -- chapter_title_1 is the legacy alias for chap_title_1; quoted RHS must
    -- survive the alias-rewrite pass unchanged.
    eq(P([=[[if:chapter_title_1="The Awakening"]hit[/if]]=],
         {chap_title_1="The Awakening"}), "hit")
    eq(P([=[[if:chapter_title_1="The Awakening"]hit[/if]]=],
         {chap_title_1="Other"}), "")
end)

test("string: combined with operators", function()
    eq(
        P("[if:series and not chapter_title_2]%S \xC2\xB7 %C1[/if]",
          {series="Foo #2", chap_title_2=""}),
        "%S \xC2\xB7 %C1"
    )
    eq(
        P("[if:series and not chapter_title_2]%S \xC2\xB7 %C1[/if]",
          {series="Foo #2", chap_title_2="Sub"}),
        ""
    )
end)

test("alias: new state key name + legacy predicate name both resolve", function()
    local r = Tokens._processConditionals("[if:chapters>5]many[/if]", { chap_count = 10 })
    eq(r, "many")
end)

-- ----------------------------------------------------------------------------
-- Cross-reference with @ref and != operator
-- ----------------------------------------------------------------------------

test("@ref: chapter_title_1 = @title when they match", function()
    eq(P("[if:chapter_title_1=@title]SAME[/if]",
         {chapter_title_1="My Book", title="My Book"}), "SAME")
end)

test("@ref: chapter_title_1 = @title when they differ", function()
    eq(P("[if:chapter_title_1=@title]SAME[/if]",
         {chapter_title_1="Part 1", title="My Book"}), "")
end)

test("@ref: not chapter_title_1 = @title (the motivating use-case)", function()
    -- Book with parts: chapter_title_1 is "Part 1", title is "My Book" → show it
    eq(P("[if:not chapter_title_1=@title]%C1[/if]",
         {chapter_title_1="Part 1", title="My Book"}), "%C1")
    -- Book without parts: chapter_title_1 IS the title → hide it
    eq(P("[if:not chapter_title_1=@title]%C1[/if]",
         {chapter_title_1="My Book", title="My Book"}), "")
end)

test("@ref: missing ref key treated as empty string", function()
    eq(P("[if:title=@nonexistent]X[/if]", {title="Foo"}), "")
    eq(P("[if:title=@nonexistent]X[/if]", {title=""}), "X")
end)

test("@ref: numeric cross-reference", function()
    eq(P("[if:chapter=@chapters]last[/if]", {chapter=10, chapters=10}), "last")
    eq(P("[if:chapter=@chapters]last[/if]", {chapter=5, chapters=10}), "")
end)

test("!=: basic not-equals with literal", function()
    eq(P("[if:a!=1]X[/if]", {a=1}), "")
    eq(P("[if:a!=1]X[/if]", {a=2}), "X")
end)

test("!=: string not-equals", function()
    eq(P("[if:author!=Anonymous]named[/if]", {author="Ursula K. Le Guin"}), "named")
    eq(P("[if:author!=Anonymous]named[/if]", {author="Anonymous"}), "")
end)

test("!=: with @ref", function()
    eq(P("[if:chapter_title_1!=@title]%C1[/if]",
         {chapter_title_1="Part 1", title="My Book"}), "%C1")
    eq(P("[if:chapter_title_1!=@title]%C1[/if]",
         {chapter_title_1="My Book", title="My Book"}), "")
end)

test("!=: nil key with != returns true", function()
    eq(P("[if:missing!=hello]X[/if]", {}), "X")
end)

test("!=: numeric not-equals", function()
    eq(P("[if:batt!=100]not full[/if]", {batt=85}), "not full")
    eq(P("[if:batt!=100]not full[/if]", {batt=100}), "")
end)

test("@ref: works with else branch", function()
    eq(P("[if:chapter_title_1=@title]dup[else]%C1[/if]",
         {chapter_title_1="Part 1", title="My Book"}), "%C1")
    eq(P("[if:chapter_title_1=@title]dup[else]%C1[/if]",
         {chapter_title_1="My Book", title="My Book"}), "dup")
end)

test("@ref: combined with and/or operators", function()
    eq(P("[if:chapter_title_1!=@title and series]%S \xC2\xB7 %C1[/if]",
         {chapter_title_1="Part 1", title="My Book", series="Saga #1"}), "%S \xC2\xB7 %C1")
    eq(P("[if:chapter_title_1!=@title and series]%S \xC2\xB7 %C1[/if]",
         {chapter_title_1="My Book", title="My Book", series="Saga #1"}), "")
end)

test("@ref: v5 state keys resolve via alias on ref lookup", function()
    -- @chapters (legacy name) should find state.chap_count via STATE_ALIAS
    eq(P("[if:chap_num=@chapters]last[/if]", {chap_num=10, chap_count=10}), "last")
end)

io.stdout:write(string.format("%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
