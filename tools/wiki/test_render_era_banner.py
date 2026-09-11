"""Unit tests for render_era_banner.py's `--reband` banner-replacement logic.

wiki-reband task (epic 16d081ab / THE WHOLE): the live wiki has pages
stamped at several different stale eras (GV24/Glory12, GV52/Glory13,
GV61/Glory16, GV62/Glory17), plus pages with no banner at all, plus pages
already current. This file pins `reband_text`'s behavior against a fixture
of each real form found in the corpus, plus the correction relayed by the
lead mid-task: `--reband` may only move the "the live game is ..." clause;
the "Verified against ..." clause (what the content was actually checked
against) must be byte-identical before and after, on every stale form.

Run: python3 -m pytest tools/wiki/test_render_era_banner.py -v
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import render_era_banner as reb  # noqa: E402

ERA_GV, ERA_GLORY = 63, 17  # current era for all tests (GV63 / GLORYVERSION 17)


def verified_against_clause(text: str) -> str:
    """Pull the 'Verified against `GV.. / Glory ..`' clause out of a banner
    line, so tests can assert it never moves."""
    for line in text.splitlines():
        m = reb.BANNER_LINE_RE.match(line.strip())
        if m:
            return f"GV{m.group(1)} / Glory {m.group(2)}"
    raise AssertionError(f"no banner line found in:\n{text}")


# --- Fixtures: one per stale form actually found in the live corpus, plus
# a page with no banner yet, plus one already current. -----------------

FIXTURE_GV24_GLORY12 = (
    "*Verified against [[versions|GV24 / Glory 12]].*\n"
    "\n"
    "**Verified against `GV24 / Glory 12` — the live game is "
    "`GV61 / GLORYVERSION 16`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

FIXTURE_GV52_GLORY13 = (
    "*Verified against `GV52 / Glory 13`, 2026-09-04.*\n"
    "\n"
    "**Verified against `GV52 / Glory 13` — the live game is "
    "`GV61 / GLORYVERSION 16`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

FIXTURE_GV61_GLORY16 = (
    "*Verified against GV61 / Glory 16.*\n"
    "\n"
    "**Verified against `GV61 / Glory 16` — the live game is "
    "`GV62 / GLORYVERSION 17`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

FIXTURE_GV62_GLORY17 = (
    "*Verified against `paintbot-v0.7.377` (GV62 / GLORYVERSION 17), "
    "2026-09-09 — see `docs/wiki/_era.md`.*\n"
    "\n"
    "**Verified against `GV62 / Glory 17` — the live game is "
    "`GV62 / GLORYVERSION 17`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

# A page whose banner already names the CURRENT era (matches real
# docs/wiki/glossary.md's live state at the start of this task) — the
# no-op case, distinct from FIXTURE_GV62_GLORY17 above whose banner still
# names GV62 and therefore needs a reband to GV63.
FIXTURE_BANNER_ALREADY_CURRENT = (
    "*Verified against `paintbot-v0.7.377` (GV62 / GLORYVERSION 17), "
    "2026-09-09 — see `docs/wiki/_era.md`.*\n"
    "\n"
    "**Verified against `GV62 / Glory 17` — the live game is "
    "`GV63 / GLORYVERSION 17`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

FIXTURE_NONE = (
    "*Verified against [[versions|GV24 / Glory 12]].*\n"
    "\n"
    "Body text with no banner at all yet.\n"
)

FIXTURE_CURRENT = (
    "*Verified against `paintbot-v0.7.392` (GV63 / GLORYVERSION 17), "
    "2026-09-09.*\n"
    "\n"
    "Body text, already current, no banner needed.\n"
)

STALE_FIXTURES = {
    "GV24/Glory12": FIXTURE_GV24_GLORY12,
    "GV52/Glory13": FIXTURE_GV52_GLORY13,
    "GV61/Glory16": FIXTURE_GV61_GLORY16,
    "GV62/Glory17": FIXTURE_GV62_GLORY17,
}


def test_reband_moves_only_the_live_game_is_clause():
    for name, fixture in STALE_FIXTURES.items():
        before_clause = verified_against_clause(fixture)
        new_text, status = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=True)
        assert status == "rebanded", f"{name}: expected 'rebanded', got {status!r}"
        after_clause = verified_against_clause(new_text)
        assert after_clause == before_clause, (
            f"{name}: 'Verified against' clause moved "
            f"({before_clause!r} -> {after_clause!r}) — --reband must never "
            f"touch it, only 'the live game is'"
        )
        assert f"the live game is `GV{ERA_GV} / GLORYVERSION {ERA_GLORY}`" in new_text
        # The page's own first line (the real stamp) must be byte-identical.
        assert new_text.splitlines()[0] == fixture.splitlines()[0]


def test_reband_on_banner_already_naming_current_era_is_a_noop():
    new_text, status = reb.reband_text(
        FIXTURE_BANNER_ALREADY_CURRENT, ERA_GV, ERA_GLORY, reband=True
    )
    assert status == "current"
    assert new_text == FIXTURE_BANNER_ALREADY_CURRENT


def test_reband_on_page_with_no_banner_inserts_one():
    new_text, status = reb.reband_text(FIXTURE_NONE, ERA_GV, ERA_GLORY, reband=True)
    assert status == "stale"
    assert f"the live game is `GV{ERA_GV} / GLORYVERSION {ERA_GLORY}`" in new_text
    assert verified_against_clause(new_text) == "GV24 / Glory 12"


def test_reband_on_current_page_is_a_noop():
    new_text, status = reb.reband_text(FIXTURE_CURRENT, ERA_GV, ERA_GLORY, reband=True)
    assert status == "current"
    assert new_text == FIXTURE_CURRENT


def test_reband_is_idempotent_across_all_fixtures():
    for name, fixture in {**STALE_FIXTURES,
                           "banner-already-current": FIXTURE_BANNER_ALREADY_CURRENT,
                           "none": FIXTURE_NONE, "current": FIXTURE_CURRENT}.items():
        once, _ = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=True)
        twice, status_twice = reb.reband_text(once, ERA_GV, ERA_GLORY, reband=True)
        assert twice == once, f"{name}: second reband pass changed the text"
        assert status_twice == "current", (
            f"{name}: second pass should report 'current', got {status_twice!r}"
        )


def test_default_mode_without_reband_leaves_existing_banner_alone():
    """Legacy/default behavior (no --reband): once a banner exists, it is
    never updated, even if the era has moved on again since it was written."""
    new_text, status = reb.reband_text(FIXTURE_GV24_GLORY12, ERA_GV, ERA_GLORY, reband=False)
    assert status == "stale-already-banded"
    assert new_text == FIXTURE_GV24_GLORY12  # byte-identical, nothing written


def test_default_mode_without_reband_still_inserts_a_missing_banner():
    new_text, status = reb.reband_text(FIXTURE_NONE, ERA_GV, ERA_GLORY, reband=False)
    assert status == "stale"
    assert f"the live game is `GV{ERA_GV} / GLORYVERSION {ERA_GLORY}`" in new_text


def test_unparsed_multiline_stamp_is_never_touched():
    """A page whose first line isn't a single-line '*...*' stamp (e.g.
    your-first-policy.md's multi-line stamp) must be left completely alone
    in both modes — a mechanical replace on it would be unsafe."""
    fixture = (
        "*Verified against `coworld` CLI package version resolving to\n"
        "`coworld==0.1.46`, on a fresh $HOME, 2026-09-09. Live ladder at\n"
        "the time of writing: paintbot-v0.7.377 (GameVersion 62 / GLORYVERSION 17).*\n"
        "\n"
        "Body text.\n"
    )
    for reband in (False, True):
        new_text, status = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=reband)
        assert status == "unparsed"
        assert new_text == fixture


def test_build_banner_matches_banner_line_re():
    banner = reb.build_banner(24, 12, 63, 17)
    assert reb.BANNER_LINE_RE.match(banner.strip())


def test_reband_finds_stamp_after_an_h1_title():
    """Matches the real live achievements/deeds pages: '# Title', blank,
    then the stamp — not on line 0."""
    fixture = (
        "# Achievements\n"
        "\n"
        "*Verified against [[versions|GV24 / Glory 12]].*\n"
        "\n"
        "Body text.\n"
    )
    new_text, status = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=True)
    assert status == "stale"
    lines = new_text.splitlines()
    assert lines[0] == "# Achievements"
    assert lines[2] == "*Verified against [[versions|GV24 / Glory 12]].*"
    assert f"the live game is `GV{ERA_GV} / GLORYVERSION {ERA_GLORY}`" in new_text
    assert verified_against_clause(new_text) == "GV24 / Glory 12"


def test_reband_bails_out_on_an_unrecognized_leading_structure():
    """A non-blank, non-heading line before any stamp is found means this
    page's shape isn't one the script understands — bail rather than
    guess where to put the banner."""
    fixture = (
        "Some unexpected leading prose, not a heading or a stamp.\n"
        "\n"
        "*Verified against [[versions|GV24 / Glory 12]].*\n"
        "\n"
        "Body text.\n"
    )
    new_text, status = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=True)
    assert status == "unparsed"
    assert new_text == fixture


def test_is_dated_log_slug():
    assert reb.is_dated_log_slug("changelog")
    assert reb.is_dated_log_slug("changelog-2026-09-04")
    assert reb.is_dated_log_slug("changelog-2026-09-08")
    assert reb.is_dated_log_slug("patch-notes")
    assert not reb.is_dated_log_slug("changelog-extra-suffix")
    assert not reb.is_dated_log_slug("glory-season-2")


# --- Gap found post-#546 review: reband_text() itself must honor
# DATED_LOG_SLUG_RE, not just reband_live.py's pre-check, so a bare local
# `--apply` over the repo (which now mirrors the changelog family) can
# never stamp a dated log page. -----------------------------------------

# Real shape of docs/wiki/changelog-2026-09-04.md and -05.md: a recognizable
# single-line stamp, no banner yet, era-stale — exactly the shape that
# would otherwise be flagged 'stale' and banner-stamped.
FIXTURE_CHANGELOG_STALE_NO_BANNER = (
    "*Covers changes that went live 2026-09-04, spanning builds "
    "0.7.317-0.7.327 (GV24 / Glory 13).*\n"
    "\n"
    "Nine things changed for players today.\n"
)


def test_reband_text_exempts_dated_log_slugs_regardless_of_reband_flag():
    for slug in ("changelog", "changelog-2026-09-04", "changelog-2026-09-05"):
        for reband in (False, True):
            new_text, status = reb.reband_text(
                FIXTURE_CHANGELOG_STALE_NO_BANNER, ERA_GV, ERA_GLORY, reband=reband,
                slug=slug,
            )
            assert status == "exempt-dated-log", (
                f"slug={slug!r} reband={reband}: expected 'exempt-dated-log', "
                f"got {status!r}"
            )
            assert new_text == FIXTURE_CHANGELOG_STALE_NO_BANNER, (
                f"slug={slug!r} reband={reband}: text must be byte-identical"
            )


def test_reband_text_without_a_slug_is_unaffected_by_the_exemption():
    """Calling reband_text with no slug (the direct-fixture style every
    other test in this file uses) must keep working exactly as before —
    the exemption only engages when a slug is actually passed."""
    new_text, status = reb.reband_text(
        FIXTURE_CHANGELOG_STALE_NO_BANNER, ERA_GV, ERA_GLORY, reband=True
    )
    assert status == "stale"
    assert new_text != FIXTURE_CHANGELOG_STALE_NO_BANNER


def test_process_page_apply_leaves_dated_changelog_pages_byte_identical(tmp_path):
    """The exact scenario the gap would have broken: an --apply pass
    (write=True) over a repo directory that contains changelog-2026-09-04.md
    and changelog-2026-09-05.md (as this repo's docs/wiki/ now does, after
    the #546 mirror) must leave both files completely untouched."""
    for slug in ("changelog-2026-09-04", "changelog-2026-09-05"):
        page = tmp_path / f"{slug}.md"
        page.write_text(FIXTURE_CHANGELOG_STALE_NO_BANNER)
        before_bytes = page.read_bytes()

        status = reb.process_page(
            page, ERA_GV, ERA_GLORY, write=True, reband=True
        )

        assert status == "exempt-dated-log", f"{slug}: got status {status!r}"
        after_bytes = page.read_bytes()
        assert after_bytes == before_bytes, (
            f"{slug}: --apply must leave dated changelog pages byte-identical"
        )


# --- patch-notes.md is structurally a changelog (versioned tables, newest
# first, keyed by build/GV/Glory) and joins the exemption set alongside the
# changelog family. Unlike the changelog fixtures above, the real
# docs/wiki/patch-notes.md already carried a leftover banner from before it
# was exempted (stamped GV24/Glory12, banded against a since-superseded
# era) — so its exemption path also has to cover stripping that banner on a
# write pass, not just staying byte-identical when there is nothing to
# strip. ---------------------------------------------------------------

FIXTURE_PATCH_NOTES_NO_BANNER = (
    "*Verified against [[versions|GV24 / Glory 12]].*\n"
    "\n"
    "The strategy-relevant change log: the versions at which the play\n"
    "itself changed, in one place.\n"
)

FIXTURE_PATCH_NOTES_WITH_BANNER = (
    "*Verified against [[versions|GV24 / Glory 12]].*\n"
    "\n"
    "**Verified against `GV24 / Glory 12` — the live game is "
    "`GV63 / GLORYVERSION 18`; treat details as unconfirmed.**\n"
    "\n"
    "The strategy-relevant change log: the versions at which the play\n"
    "itself changed, in one place.\n"
)


def test_patch_notes_is_exempt_and_byte_identical_with_no_banner():
    for reband in (False, True):
        new_text, status = reb.reband_text(
            FIXTURE_PATCH_NOTES_NO_BANNER, ERA_GV, ERA_GLORY, reband=reband,
            slug="patch-notes",
        )
        assert status == "exempt-dated-log"
        assert new_text == FIXTURE_PATCH_NOTES_NO_BANNER


def test_patch_notes_write_pass_strips_its_leftover_banner():
    """patch-notes.md carried a banner from before it was exempted. A write
    pass must strip it — regardless of --reband — so the page settles into
    its steady exempt, banner-free state instead of carrying a stale banner
    forever (the default, additive-only mode otherwise never removes an
    existing banner)."""
    for reband in (False, True):
        new_text, status = reb.reband_text(
            FIXTURE_PATCH_NOTES_WITH_BANNER, ERA_GV, ERA_GLORY, reband=reband,
            slug="patch-notes",
        )
        assert status == "banner-removed"
        assert new_text == FIXTURE_PATCH_NOTES_NO_BANNER


def test_process_page_apply_strips_patch_notes_leftover_banner(tmp_path):
    page = tmp_path / "patch-notes.md"
    page.write_text(FIXTURE_PATCH_NOTES_WITH_BANNER)

    status = reb.process_page(page, ERA_GV, ERA_GLORY, write=True, reband=False)

    assert status == "banner-removed"
    assert page.read_text() == FIXTURE_PATCH_NOTES_NO_BANNER


# --- Gap found post-#490: a page's own stamp can be brought up to the live
# era (a content re-trace) while a banner inserted during its stale window
# is still sitting there. `--check` must fail on this (same severity as
# `stale`) and `--reband` must remove the now-obsolete banner — mirroring
# exactly how it was inserted (blank line + banner line right after the
# stamp) so the page returns byte-for-byte to its pre-banner shape. The
# page's own stamp is the only trusted signal for this decision; the
# banner's own "the live game is" clause is deliberately never consulted,
# so even a hand-tampered clause can't hide a leftover banner. ---------

# New (backtick) stamp form, already current, with a leftover banner whose
# own clause still names an older era (as it would if the page's stamp was
# re-traced to GV63 sometime after the banner was written against GV62).
FIXTURE_CURRENT_NEW_FORM_ORIGINAL = (
    "*Verified against `paintbot-v0.7.392` (GV63 / GLORYVERSION 17), "
    "2026-09-11 — see `docs/wiki/_era.md`.*\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER = (
    "*Verified against `paintbot-v0.7.392` (GV63 / GLORYVERSION 17), "
    "2026-09-11 — see `docs/wiki/_era.md`.*\n"
    "\n"
    "**Verified against `GV63 / Glory 17` — the live game is "
    "`GV62 / GLORYVERSION 17`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

# Old ([[versions|...]]) stamp form, same scenario — confirms both
# recognized stamp shapes feed the same detection.
FIXTURE_CURRENT_OLD_FORM_ORIGINAL = (
    "*Verified against [[versions|GV63 / Glory 17]].*\n"
    "\n"
    "Body text unrelated to the banner.\n"
)

FIXTURE_CURRENT_OLD_FORM_WITH_STALE_BANNER = (
    "*Verified against [[versions|GV63 / Glory 17]].*\n"
    "\n"
    "**Verified against `GV63 / Glory 17` — the live game is "
    "`GV63 / GLORYVERSION 17`; treat details as unconfirmed.**\n"
    "\n"
    "Body text unrelated to the banner.\n"
)


def test_current_stamp_with_stale_banner_check_fails_and_reband_removes_it():
    """(a) current stamp + stale banner: --check (reband=False) must report
    'stale-banner' without touching the page; --reband must remove exactly
    the banner line (and the blank line its insertion added), leaving the
    page byte-for-byte identical to how it looked before the banner ever
    existed."""
    fixture = FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER
    original = FIXTURE_CURRENT_NEW_FORM_ORIGINAL

    checked_text, checked_status = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=False)
    assert checked_status == "stale-banner"
    assert checked_text == fixture  # read-only: untouched

    rebanded_text, rebanded_status = reb.reband_text(fixture, ERA_GV, ERA_GLORY, reband=True)
    assert rebanded_status == "banner-removed"
    assert rebanded_text == original


def test_stale_banner_detection_outranks_the_banners_own_clause():
    """The banner in the fixture above claims 'the live game is GV62' (an
    old era) — if that clause were trusted, the page would look like it
    still needs a reband. It must not be trusted: the page's own stamp
    (GV63, current) is what decides, so the banner is removed outright
    rather than rebanded to a new clause."""
    _, status = reb.reband_text(
        FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER, ERA_GV, ERA_GLORY, reband=True
    )
    assert status == "banner-removed"


def test_old_stamp_with_banner_keeps_existing_reband_behavior():
    """(b) old stamp + banner: unchanged behaviour — the clause is updated
    (or left alone without --reband) and the banner is kept, never removed,
    across every stale fixture in the corpus."""
    for name, fixture in STALE_FIXTURES.items():
        left_alone_text, left_alone_status = reb.reband_text(
            fixture, ERA_GV, ERA_GLORY, reband=False
        )
        assert left_alone_status == "stale-already-banded", name
        assert left_alone_text == fixture, name

        rebanded_text, rebanded_status = reb.reband_text(
            fixture, ERA_GV, ERA_GLORY, reband=True
        )
        assert rebanded_status == "rebanded", name
        assert any(
            reb.BANNER_LINE_RE.match(line.strip()) for line in rebanded_text.splitlines()
        ), f"{name}: banner must still be present after reband, not removed"


def test_current_stamp_no_banner_is_a_noop_both_modes():
    """(c) current stamp + no banner: no-op in both --check and --reband
    modes — nothing to remove, nothing to insert."""
    for reband in (False, True):
        new_text, status = reb.reband_text(FIXTURE_CURRENT, ERA_GV, ERA_GLORY, reband=reband)
        assert status == "current"
        assert new_text == FIXTURE_CURRENT


def test_stale_banner_detection_recognizes_both_stamp_forms():
    """(d) both the old `[[versions|...]]` form and the new backtick form
    are recognized as the page's own stamp for this detection."""
    cases = [
        ("new-form", FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER, FIXTURE_CURRENT_NEW_FORM_ORIGINAL),
        ("old-form", FIXTURE_CURRENT_OLD_FORM_WITH_STALE_BANNER, FIXTURE_CURRENT_OLD_FORM_ORIGINAL),
    ]
    for name, with_banner, original in cases:
        checked_text, checked_status = reb.reband_text(with_banner, ERA_GV, ERA_GLORY, reband=False)
        assert checked_status == "stale-banner", name
        assert checked_text == with_banner, name

        removed_text, removed_status = reb.reband_text(with_banner, ERA_GV, ERA_GLORY, reband=True)
        assert removed_status == "banner-removed", name
        assert removed_text == original, name


def test_banner_removal_is_idempotent():
    """A second reband pass over an already-removed banner must report
    'current' and change nothing further."""
    once, once_status = reb.reband_text(
        FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER, ERA_GV, ERA_GLORY, reband=True
    )
    assert once_status == "banner-removed"
    twice, twice_status = reb.reband_text(once, ERA_GV, ERA_GLORY, reband=True)
    assert twice_status == "current"
    assert twice == once


def test_process_page_apply_removes_stale_banner_from_current_page(tmp_path):
    """End-to-end through process_page (write=True, reband=True), matching
    how the CLI's --reband apply pass touches a real file on disk."""
    page = tmp_path / "some-page.md"
    page.write_text(FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER)

    status = reb.process_page(page, ERA_GV, ERA_GLORY, write=True, reband=True)

    assert status == "banner-removed"
    assert page.read_text() == FIXTURE_CURRENT_NEW_FORM_ORIGINAL


def test_process_page_check_does_not_write_on_stale_banner(tmp_path):
    """process_page must never write in check mode (write=False), even for
    the new stale-banner case."""
    page = tmp_path / "some-page.md"
    page.write_text(FIXTURE_CURRENT_NEW_FORM_WITH_STALE_BANNER)
    before_bytes = page.read_bytes()

    status = reb.process_page(page, ERA_GV, ERA_GLORY, write=False, reband=False)

    assert status == "stale-banner"
    assert page.read_bytes() == before_bytes
