/**
 * Mermaid diagram initialization for MkDocs Material
 * - document$ はMaterial SPA ナビゲーション時も発火する
 * - Material built-in Mermaid サポートが初期化されない場合のフォールバック
 */
document$.subscribe(function () {
  // Material がすでに処理済みの場合はスキップ
  var processed = document.querySelectorAll('.mermaid[data-processed="true"]');
  if (processed.length > 0) return;

  // コードブロック内の mermaid クラスを検索して初期化
  if (typeof mermaid !== 'undefined') {
    mermaid.initialize({
      startOnLoad: false,
      theme: document.documentElement.getAttribute('data-md-color-scheme') === 'slate'
        ? 'dark'
        : 'default',
      securityLevel: 'loose',
      fontFamily: '"Noto Sans JP", sans-serif',
    });

    var blocks = document.querySelectorAll('code.mermaid, pre code.language-mermaid');
    blocks.forEach(function (block, index) {
      var parent = block.closest('pre') || block.parentElement;
      var code = block.textContent;
      var id = 'mermaid-diagram-' + index + '-' + Date.now();

      mermaid.render(id, code).then(function (result) {
        var wrapper = document.createElement('div');
        wrapper.className = 'mermaid-wrapper';
        wrapper.innerHTML = result.svg;
        parent.parentNode.replaceChild(wrapper, parent);
      }).catch(function (err) {
        console.warn('[Mermaid] render error on block #' + index + ':', err);
      });
    });
  }
});
