-- Standalone macOS-style application switching, provided by zc.app-switcher.
-- Replace the default Alt+Tab window cycling and bring-to-top bindings.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")
o.bind("ALT + TAB", "Next application", hl.dsp.event("zc-app-switcher:next"))
o.bind("ALT + SHIFT + TAB", "Previous application", hl.dsp.event("zc-app-switcher:previous"))
hl.unbind("ALT + grave")
hl.unbind("ALT + SHIFT + grave")
o.bind("ALT + grave", "Next window of current application", hl.dsp.event("zc-app-switcher:window-next"))
o.bind("ALT + SHIFT + grave", "Previous window of current application", hl.dsp.event("zc-app-switcher:window-previous"))

-- Send modifier releases through the same ordered IPC stream as the first Tab.
-- This also handles taps released before the overlay acquires keyboard focus.
-- Keycodes here are XKB codes, as reported by input.keyboard.key.
hl.on("input.keyboard.key", function(code, _, state)
  if state ~= 0 then return end
  if (code == 64 and not hl.is_key_down("Alt_R"))
      or (code == 108 and not hl.is_key_down("Alt_L")) then
    hl.dispatch(hl.dsp.event("zc-app-switcher:accept"))
  end
end)

hl.layer_rule({
  match = { namespace = "^zc-app-switcher$" },
  blur = true,
  ignore_alpha = 0.1,
  no_anim = true,
})
