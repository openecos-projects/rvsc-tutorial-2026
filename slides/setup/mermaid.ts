import { defineMermaidSetup } from "@slidev/types";

export default defineMermaidSetup(() => {
  return {
    // 与正文保持一致:Gelasio(西文衬线)+ Noto Sans SC Variable(中文黑体)
    fontFamily: "'Gelasio', 'Noto Sans SC Variable', sans-serif",
  };
});
