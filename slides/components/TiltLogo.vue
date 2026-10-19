<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref } from "vue";
import logoUrl from "../assets/ecos-logo.png";

const el = ref<HTMLElement>();
let raf = 0;
let hovering = false;

// 鼠标悬停时的目标倾斜角
let hoverRx = 0;
let hoverRy = 0;
// 当前实际倾斜角(每帧向目标平滑逼近)
let curRx = 0;
let curRy = 0;
let curTy = 0;

const HOVER_TILT = 14; // 悬停最大倾斜角(度)

function onMove(e: MouseEvent) {
  const rect = el.value?.getBoundingClientRect();
  if (!rect) return;
  const px = (e.clientX - rect.left) / rect.width - 0.5; // -0.5 .. 0.5
  const py = (e.clientY - rect.top) / rect.height - 0.5;
  hoverRy = px * HOVER_TILT * 2;
  hoverRx = -py * HOVER_TILT * 2;
}

onMounted(() => {
  // 尊重系统的"减少动态效果"设置
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

  const start = performance.now();
  const loop = (now: number) => {
    const s = (now - start) / 1000;
    // 前 2 秒振幅渐入,与封面入场动画自然衔接
    const amp = Math.min(1, s / 2);
    // 常驻环境摇摆
    const ambRx = Math.sin(s * 0.9) * 6 * amp;
    const ambRy = Math.cos(s * 0.7) * 9 * amp;
    const ambTy = Math.sin(s * 1.4) * 5 * amp;
    // 悬停时目标切换为鼠标倾斜,否则回到环境摇摆;浮动始终保留
    const targetRx = hovering ? hoverRx : ambRx;
    const targetRy = hovering ? hoverRy : ambRy;
    const k = hovering ? 0.18 : 0.06; // 悬停跟随更跟手,回落更从容
    curRx += (targetRx - curRx) * k;
    curRy += (targetRy - curRy) * k;
    curTy += (ambTy - curTy) * 0.06;
    if (el.value)
      el.value.style.transform = `perspective(600px) rotateX(${curRx}deg) rotateY(${curRy}deg) translateY(${curTy}px)`;
    raf = requestAnimationFrame(loop);
  };
  raf = requestAnimationFrame(loop);
});

onBeforeUnmount(() => cancelAnimationFrame(raf));
</script>

<template>
  <div
    ref="el"
    class="tilt-logo"
    @mousemove="onMove"
    @mouseenter="hovering = true"
    @mouseleave="hovering = false"
  >
    <img :src="logoUrl" alt="ECOS Studio logo" draggable="false" />
  </div>
</template>

<style scoped>
.tilt-logo {
  display: block;
  width: 8rem;
  margin: 0 auto 1.5rem;
  cursor: pointer;
  will-change: transform;
}
.tilt-logo img {
  display: block;
  width: 100%;
  user-select: none;
  transition:
    transform 0.35s cubic-bezier(0.22, 1, 0.36, 1),
    filter 0.35s ease;
  /* 常驻的柔和橙色光晕,hover 时增强 */
  filter: drop-shadow(0 8px 18px rgba(239, 108, 0, 0.15));
}
.tilt-logo:hover img {
  transform: scale(1.08);
  filter: drop-shadow(0 14px 28px rgba(239, 108, 0, 0.38));
}
</style>
