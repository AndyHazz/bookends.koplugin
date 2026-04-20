# Bookends 4.1.0 — release notes (draft)

## Breaking: conditional predicate renames

Three conditional predicates have been renamed for clarity. Update any preset that used the old names.

| Old                        | New                          |
|----------------------------|------------------------------|
| `[if:percent>N]`           | `[if:book_pct>N]`            |
| `[if:chapter>N]`           | `[if:chapter_pct>N]`         |
| `[if:pages>N]`             | `[if:session_pages>N]`       |

The name `chapter` now means the **current chapter number** (matching the `%j` token), and a new `chapters` predicate exposes the total chapter count (matching `%J`). If you had a preset around `[if:chapter>50]` meaning "more than halfway through current chapter", that expression now compares *chapter number* to 50 and will silently render differently. Update it to `[if:chapter_pct>50]`.

None of the presets in the community gallery use these old names, so gallery presets are unaffected.

## New: nested conditionals

`[if:...][if:...]...[/if][/if]` now works to any depth and composes with `[else]` on either level.

```
[if:time<18:30][if:time>=18:00]between 6 and 6:30[/if][/if]
```

## New: boolean operators and grouping

`and`, `or`, `not` are now supported inside conditional predicates, with parens for grouping. Standard precedence (`not` binds tightest, `or` loosest).

```
[if:time>=18:00 and time<18:30]6–6:30[/if]
[if:day=Sat or day=Sun]weekend[/if]
[if:not charging=yes]battery[/if]
[if:(day=Sat or day=Sun) and batt<50]low on a weekend[/if]
```

## New: chapter number / count predicates

Requested in issue #23.

```
[if:chapters>20]Long read[/if]
[if:chapter=1]Foreword[/if]
```

## New: text-field emptiness and equality predicates

Book-metadata and chapter-title strings are now testable in conditionals. Empty strings are falsy, so a bare-key truthy check is the idiomatic emptiness test.

```
[if:chapter_title_2]%C2[else]%C1[/if]    — show sub-chapter title if present, parent otherwise
[if:not series]Standalone[/if]           — books not in a series
[if:author=Anonymous]?[/if]              — string equality
```

Predicates added: `title`, `author`, `series`, `chapter_title`, `chapter_title_1`, `chapter_title_2`, `chapter_title_3`.
