<script setup lang="ts">
import { onMounted, ref } from "vue";

// 现场才公布的章节：输入口令后解锁，同一浏览器内所有 <SecretGate> 一起解锁。
// 只防偶然翻到，不是访问控制 —— 内容仍在前端 bundle 里。
const STORAGE_KEY = "rvsc2026-agent-section";
// sha256("ecos2026")，避免口令以明文出现在源码里
const PASS_SHA256 =
  "e975fa54d8e2e30002e4473c8f1a81d94ebed89598e4f56aa47007a50a744136";

const unlocked = ref(false);
const input = ref("");
const error = ref(false);

async function sha256(text: string): Promise<string> {
  const bytes = new TextEncoder().encode(text);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function submit() {
  const hash = await sha256(input.value.trim().toLowerCase());
  if (hash === PASS_SHA256) {
    localStorage.setItem(STORAGE_KEY, "1");
    unlocked.value = true;
    // 通知同一页面里的其他 <SecretGate>
    window.dispatchEvent(new Event(STORAGE_KEY));
  } else {
    error.value = true;
  }
}

onMounted(() => {
  unlocked.value = localStorage.getItem(STORAGE_KEY) === "1";
  window.addEventListener(STORAGE_KEY, () => (unlocked.value = true));
});
</script>

<template>
  <slot v-if="unlocked" />
  <div v-else class="secret-gate">
    <svg
      class="secret-gate-icon"
      viewBox="0 0 24 24"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.25"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <rect x="5" y="10.5" width="14" height="10" rx="2" />
      <path d="M8 10.5V7a4 4 0 0 1 8 0v3.5" />
      <path d="M12 14.5v2.5" />
    </svg>
    <p class="secret-gate-title">
      <span class="secret-gate-redacted" aria-label="内容已隐藏"></span>
    </p>
    <!-- @keydown.stop:避免输入时 Slidev 的快捷键翻页 -->
    <form class="secret-gate-form" @submit.prevent="submit" @keydown.stop>
      <label class="sr-only" for="secret-gate-input">口令</label>
      <input
        id="secret-gate-input"
        v-model="input"
        type="password"
        autocomplete="off"
        placeholder="口令"
        :aria-invalid="error"
        aria-describedby="secret-gate-error"
        @input="error = false"
      />
      <button type="submit">解锁</button>
    </form>
    <p id="secret-gate-error" class="secret-gate-error" role="alert">
      {{ error ? "口令不对，再试一次" : "" }}
    </p>
  </div>
</template>

<style scoped>
.secret-gate {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 0.75rem;
  min-height: 60%;
  margin-top: 3rem;
  text-align: center;
}

.secret-gate-icon {
  width: 2.75rem;
  height: 2.75rem;
  color: var(--rp-muted);
}

.secret-gate-title {
  font-size: 1.1rem;
}

/* 与目录里被涂黑的条目同一画法 */
.secret-gate-redacted {
  display: inline-block;
  width: 14em;
  height: 1em;
  vertical-align: middle;
  background-color: var(--rp-text);
  border-radius: 0.1em;
}

.secret-gate-form {
  display: flex;
  gap: 0.5rem;
}

.secret-gate-form input {
  padding: 0.4rem 0.75rem;
  border: 1px solid var(--rp-hl-high);
  border-radius: 0.375rem;
  background: var(--rp-surface);
  color: var(--rp-text);
}

.secret-gate-form button {
  padding: 0.4rem 1rem;
  border-radius: 0.375rem;
  background: var(--rp-pine);
  color: var(--rp-base);
}

.secret-gate-form input:focus-visible,
.secret-gate-form button:focus-visible {
  outline: 2px solid var(--rp-iris);
  outline-offset: 2px;
}

.secret-gate-error {
  min-height: 1.5em;
  color: var(--rp-love);
  font-size: 0.9rem;
}

.sr-only {
  position: absolute;
  width: 1px;
  height: 1px;
  overflow: hidden;
  clip: rect(0 0 0 0);
  white-space: nowrap;
}
</style>
