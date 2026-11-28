// Phone: collapse every column but DOING (accordion); desktop keeps all open.
if (matchMedia("(max-width: 800px)").matches)
  document.querySelectorAll("details.col").forEach(function (d) {
    if (!d.classList.contains("cDOING")) d.removeAttribute("open");
  });
