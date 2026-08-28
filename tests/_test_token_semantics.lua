-- The conformance fixture IS the parity contract between bookends and
-- bookshelf (bookshelf #348). This suite runs it against the vendored
-- token_semantics.lua. The identical suite exists in bookshelf; if the two
-- ever disagree, one repo edited a vendored file alone.
--
-- Usage: lua tests/_test_token_semantics.lua

local Semantics = dofile("token_semantics.lua")
local fixture   = dofile("token_conformance.lua")

-- LuaJIT/5.1 expose `unpack`, 5.2+ `table.unpack`. Fixture rows carry an
-- explicit `n` because args legitimately contain trailing nils (e.g. a nil
-- capacity), and `#args` would truncate them.
local unpack = table.unpack or unpack

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "")
            .. " expected=" .. string.format("%q", tostring(expected))
            .. " got=" .. string.format("%q", tostring(actual)), 2)
    end
end

test("fixture is non-empty", function()
    assert(#fixture > 0, "conformance fixture has no rows")
end)

test("every fixture row names a real function", function()
    for _i, row in ipairs(fixture) do
        if type(Semantics[row.fn]) ~= "function" then
            error("row " .. _i .. " names unknown function " .. tostring(row.fn))
        end
    end
end)

for _i, row in ipairs(fixture) do
    test(string.format("row %d: %s -> %q (%s)",
                       _i, row.fn, row.expect, row.why or ""), function()
        local got = Semantics[row.fn](unpack(row.args, 1, row.n))
        eq(got, row.expect, row.fn)
    end)
end

print(pass .. " passed, " .. fail .. " failed")
os.exit(fail == 0 and 0 or 1)
