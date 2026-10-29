"""JON-812: Home, Settings and Browse models lay their content out as sized widgets (docs/design.md, Dashboards). The
layout is CSS and the page's markup: these pin the pieces other code (and the next widgets) plug into."""

import re

from portal.app import STATIC


def read(name):
    return (STATIC / name).read_text(encoding="utf-8")


def test_homes_first_row_and_update_card_are_wrapped_for_the_grid():
    html = read("index.html")
    top = re.search(r'<div class="home-top">(.*?)\n    </div>', html, re.S)
    assert top and 'id="get-started"' in top.group(1) and 'id="continue"' in top.group(1)
    # the update card: what is new (and JON-815's service versions) on the left, what happens and the button on the right
    main = re.search(r'<div class="update-main">(.*?)\n      </div>\n      <div class="update-side">(.*?)</section>', html, re.S)
    assert main and 'id="update-releases"' in main.group(1) and 'id="update-notes"' in main.group(1)
    assert 'id="update-steps"' in main.group(2) and 'id="update-now"' in main.group(2)


def test_homes_widgets_are_placed_by_name_and_follow_the_pages_width():
    css = read("app.css")
    assert "container: home / inline-size" in css
    for name in ("spend", "svc", "models", "logins", "maint", "claude"):
        assert f"grid-area: {name}" in css
    assert "@container home (min-width: 760px)" in css and "@container home (min-width: 1060px)" in css
    assert "1180px" not in css      # no fixed cap that wastes a wide screen
    # no window-width rule fights the container: the walkthrough's wide sidebar is handled by the page's own width
    assert "tour-open .grid" not in read("tour.css")


def test_long_widgets_scroll_inside_their_card():
    css = read("app.css")
    assert re.search(r"\.update-releases \{ max-height: [\d.]+rem; overflow-y: auto; \}", css)
    assert ".continue .cont-list { max-height" in css
    assert ".models .table-wrap { max-height" in css


def test_the_models_table_becomes_cards_by_its_own_width_not_the_windows():
    css = read("mobile.css")
    assert "@container models-card (max-width:" in css and "container: models-card" in read("app.css")


def test_settings_providers_are_tabs_and_long_lists_fold():
    js, css = read("settings.js"), read("settings.css")
    assert "function showGroup(" in js and 'body.classList.add("set-tabbed")' in js
    assert 'tab) showGroup(' in js.replace("if (tab) ", "tab) ")   # an address opens its tab
    # one group at a time, whatever the groups are called (Local models had no rule while each was hidden by name)
    assert 'classList.toggle("set-tab-off", ch.dataset.group !== name)' in js
    assert "#settings:not(.set-finding) .set-tabbed > .set-tab-off { display: none; }" in css   # a search shows every tab
    assert '.set-tabbed[data-group="' not in css
    assert '"set-more set-fold"' in js                           # the rest of Advanced / About: More settings' rule (a search opens it)


def test_browse_models_is_a_grid():
    css = read("models.css")
    assert re.search(r"\.mb-list \{[^}]*display: grid; grid-template-columns: repeat\(auto-fill", css)
