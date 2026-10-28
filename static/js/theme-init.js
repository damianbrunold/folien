// Loaded in <head> without defer: applies a theme the user pinned with the
// toggle before the first paint, so the page never flashes the wrong
// palette. Nothing pinned: the CSS follows the OS setting.
(function () {
  try {
    var t = localStorage.getItem("theme");
    if (t === "dark" || t === "light") {
      document.documentElement.setAttribute("data-theme", t);
    }
  } catch (e) {}
})();
