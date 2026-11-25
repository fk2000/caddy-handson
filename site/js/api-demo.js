(function () {
  var button = document.querySelector("#api-button");
  var out = document.querySelector("#api-result");
  if (!button || !out) {
    return;
  }

  button.addEventListener("click", function () {
    out.textContent = "問い合わせ中…";
    fetch("/api/hello", { headers: { Accept: "application/json" } })
      .then(function (res) {
        return res.text().then(function (text) {
          if (!res.ok) {
            throw new Error("HTTP " + res.status + "\n" + text.slice(0, 240));
          }
          out.textContent = text;
        });
      })
      .catch(function (err) {
        out.textContent =
          "応答を読めませんでした。\n" +
          String(err && err.message ? err.message : err) +
          "\n手元の Compose では 200 の JSON が返ります。Render の単体コンテナでは、このパスは配っていません。";
      });
  });
})();
