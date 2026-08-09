# Deferred items — quick 260809-ipc

Out-of-scope discoveries made while executing the plan. Logged, not fixed
(SCOPE BOUNDARY: only issues directly caused by this task's changes are
auto-fixed).

## 1. The modifier chip row overflows horizontally at 360dp width

**Found during:** Task 3, writing the B2 regression guard on a 360x640
viewport.

**Symptom:** `A RenderFlex overflowed by 7.3 pixels on the right.` The
overflowing Flex is `ModifierChip`'s inner `Row` (`modifier_chip.dart:76`),
constrained to 74dp — a quarter of the chip row minus the chip's 1px border
each side. The `Shift` label at 16/w600 measures ~81.3dp.

**Why it is NOT this task's:** the geometry is unchanged and shared.
`KeyboardScreen._chipRow` (shipped 10-05) is `Padding(h16/v8)` around four
`Expanded` chips with 8dp gaps; the docked panel that shipped before this task
had the identical arithmetic (`Container(padding: EdgeInsets.all(16))` + the
same row). Both overflow at 360dp with or without this change. It only became
visible now because no test had ever driven a 360dp-wide viewport with a chip
row mounted.

**Where it is tolerated:** the 360x640 B2 guard in `trackpad_screen_test.dart`
drains it explicitly, asserts every drained error is that one, and asserts the
drain count is non-zero — so the day the chip row is fixed, that test fails and
points at this entry.

**Possible fixes when picked up:** `FittedBox`/`AutoSizeText` on the label, a
smaller label face below some width, or dropping the row padding to 8dp on
narrow devices. Affects BOTH keyboard surfaces, so it wants its own task.

## 2. A locked modifier survives a panel COLLAPSE

Pre-existing and explicitly out of scope per the plan
(`<out_of_scope>`: "Changing what a panel COLLAPSE does to a locked
modifier"). Collapsing unmounts the caps (so held caps release) but the panel
State survives, so a LOCKED modifier stays physically held on the PC with no
visible chip to un-lock it until the panel is reopened. Shipped behavior,
preserved verbatim; Task 1's new collapse test deliberately pins the CAP half
only. Recorded here because it is a real (if minor) stuck-input path.
