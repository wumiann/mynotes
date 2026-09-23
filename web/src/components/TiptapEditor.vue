<script setup lang="ts">
import { ref, watch } from 'vue';
import { EditorContent, useEditor } from '@tiptap/vue-3';
import StarterKit from '@tiptap/starter-kit';
import Image from '@tiptap/extension-image';
import { TextSelection } from '@tiptap/pm/state';
import { promptDialog } from '../lib/dialog';

const props = withDefaults(
  defineProps<{ content: Record<string, unknown>; editable?: boolean }>(),
  { editable: true },
);
const emit = defineEmits<{
  (e: 'update', json: Record<string, unknown>): void;
  (e: 'insert-image'): void;
  (e: 'image-file', file: File): void;
}>();

// isActive 需要在选区/事务变化时重新求值，用 tick 强制依赖
const tick = ref(0);

const editor = useEditor({
  content: props.content,
  extensions: [StarterKit, Image.configure({ inline: false })],
  editable: props.editable,
  editorProps: {
    // 点击最后一行下方的空白区：自动扩展一行并把光标放进去（类似在线文档）
    handleClick: (view, _pos, event) => {
      const { state } = view;
      const end = state.doc.content.size;
      // 最后一行底边坐标；点击位置在其下方几个像素外才算“点下一行”
      const lastLineBottom = view.coordsAtPos(Math.max(0, end - 1)).bottom;
      if (event.clientY <= lastLineBottom + 6) return false;
      const lastNode = state.doc.lastChild;
      const tr = state.tr;
      if (lastNode?.type.name === 'paragraph' && !lastNode.content.size) {
        // 末尾已是空行：光标直接移入，不再重复加行
        tr.setSelection(TextSelection.create(tr.doc, end - 1));
      } else {
        tr.insert(end, state.schema.nodes.paragraph.create());
        tr.setSelection(TextSelection.create(tr.doc, tr.doc.content.size - 1));
      }
      view.dispatch(tr.scrollIntoView());
      return true;
    },
    // 粘贴 / 拖入图片文件：交给父组件上传后插入
    handlePaste: (_view, event) => {
      const files = Array.from(event.clipboardData?.files ?? []).filter((f) =>
        f.type.startsWith('image/'),
      );
      if (!files.length) return false;
      files.forEach((f) => emit('image-file', f));
      return true;
    },
    handleDrop: (_view, event, _slice, moved) => {
      if (moved) return false;
      const files = Array.from(event.dataTransfer?.files ?? []).filter((f) =>
        f.type.startsWith('image/'),
      );
      if (!files.length) return false;
      files.forEach((f) => emit('image-file', f));
      return true;
    },
  },
  onTransaction: () => {
    tick.value++;
  },
  onUpdate: ({ editor }) => {
    emit('update', editor.getJSON());
  },
});

watch(
  () => props.content,
  (c) => {
    const ed = editor.value;
    if (!ed) return;
    if (JSON.stringify(ed.getJSON()) !== JSON.stringify(c)) {
      ed.commands.setContent(c, { emitUpdate: false });
    }
  },
);

watch(
  () => props.editable,
  (v) => editor.value?.setEditable(v, false),
);

function isActive(name: string, attrs?: Record<string, unknown>): boolean {
  void tick.value;
  return editor.value?.isActive(name, attrs) ?? false;
}

function toggleLink(): void {
  const ed = editor.value;
  if (!ed) return;
  if (ed.isActive('link')) {
    ed.chain().focus().unsetLink().run();
    return;
  }
  void promptDialog({
    title: '插入链接',
    placeholder: 'https://',
    defaultValue: 'https://',
    confirmText: '插入',
  }).then((url) => {
    if (url && url !== 'https://') {
      editor.value?.chain().focus().extendMarkRange('link').setLink({ href: url }).run();
    }
  });
}

defineExpose({
  insertImage: (url: string) => {
    editor.value?.chain().focus().setImage({ src: url }).run();
  },
  getPlainText: () => editor.value?.getText({ blockSeparator: '\n' }) ?? '',
});
</script>

<template>
  <div class="editor-body">
    <div v-if="editor" class="toolbar">
      <button type="button" class="tb-b" :class="{ on: isActive('bold') }" title="加粗"
        @mousedown.prevent @click="editor?.chain().focus().toggleBold().run()"><b>B</b></button>
      <button type="button" class="tb-i" :class="{ on: isActive('italic') }" title="斜体"
        @mousedown.prevent @click="editor?.chain().focus().toggleItalic().run()"><i>I</i></button>
      <button type="button" class="tb-s" :class="{ on: isActive('strike') }" title="删除线"
        @mousedown.prevent @click="editor?.chain().focus().toggleStrike().run()"><s>S</s></button>
      <span class="sep"></span>
      <button type="button" :class="{ on: isActive('heading', { level: 2 }) }" title="大标题"
        @mousedown.prevent @click="editor?.chain().focus().toggleHeading({ level: 2 }).run()">H1</button>
      <button type="button" :class="{ on: isActive('heading', { level: 3 }) }" title="小标题"
        @mousedown.prevent @click="editor?.chain().focus().toggleHeading({ level: 3 }).run()">H2</button>
      <span class="sep"></span>
      <button type="button" :class="{ on: isActive('bulletList') }" title="无序列表"
        @mousedown.prevent @click="editor?.chain().focus().toggleBulletList().run()">• 列表</button>
      <button type="button" :class="{ on: isActive('orderedList') }" title="有序列表"
        @mousedown.prevent @click="editor?.chain().focus().toggleOrderedList().run()">1. 列表</button>
      <button type="button" :class="{ on: isActive('blockquote') }" title="引用"
        @mousedown.prevent @click="editor?.chain().focus().toggleBlockquote().run()">引用</button>
      <span class="sep"></span>
      <button type="button" :class="{ on: isActive('code') }" title="行内代码"
        @mousedown.prevent @click="editor?.chain().focus().toggleCode().run()">代码</button>
      <button type="button" :class="{ on: isActive('codeBlock') }" title="代码块"
        @mousedown.prevent @click="editor?.chain().focus().toggleCodeBlock().run()">代码块</button>
      <button type="button" :class="{ on: isActive('link') }" title="链接"
        @mousedown.prevent @click="toggleLink">链接</button>
      <span class="sep"></span>
      <button type="button" title="插入图片" @mousedown.prevent @click="emit('insert-image')">图片</button>
      <span class="sep"></span>
      <button type="button" title="撤销" @mousedown.prevent @click="editor?.chain().focus().undo().run()">↩</button>
      <button type="button" title="重做" @mousedown.prevent @click="editor?.chain().focus().redo().run()">↪</button>
    </div>
    <EditorContent :editor="editor" class="tiptap-content" />
  </div>
</template>
