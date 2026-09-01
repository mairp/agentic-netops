declare module 'html-parse-stringify' {
  namespace HTML {
    interface TagNode {
      type: 'tag';
      name: string;
      voidElement: boolean;
      attrs: Record<string, string | undefined>;
      children: Node[];
    }

    interface TextNode {
      type: 'text';
      content: string;
    }

    interface CommentNode {
      type: 'comment';
      comment: string;
    }

    interface ComponentNode {
      type: 'component';
      name: string;
      attrs: Record<string, string | undefined>;
      voidElement: boolean;
      children: [];
    }

    type Node = TagNode | TextNode | CommentNode | ComponentNode;

    interface ParseOptions {
      components?: Record<string, boolean>;
    }

    function parse(html: string, options?: ParseOptions): Node[];
    function stringify(doc: Node[]): string;
  }

  // the CommonJS build assigns `module.exports = { parse, stringify }` with
  // no `default` property, so `export =` is the only declaration shape that
  // is correct both with and without esModuleInterop
  export = HTML;
}
