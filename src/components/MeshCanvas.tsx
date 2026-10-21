import { useEffect, useRef } from "react";
import type { MeshNode } from "../types";
import type { SimConfig } from "../simulation";
import type { RfParams } from "../rf";
import { canReach, maxRangeM, rssiModel, normRssi } from "../rf";

interface Props {
  nodes: MeshNode[];
  config: SimConfig;
  rf: RfParams;
  selectedId: string | null;
  onSelect: (id: string) => void;
  showLinks: boolean;
  showRanges: boolean;
  /** Bumped by the parent on every simulation update to trigger a redraw. */
  frame: number;
}

const TARGET_CANVAS_PX = 640;

export function MeshCanvas({ nodes, config, rf, selectedId, onSelect, showLinks, showRanges, frame }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const scaleRef = useRef(1);

  // Metres -> pixels. The world is now a physical 100x100 m area (skills/08),
  // so the canvas scales to fit rather than treating metres as pixels.
  const scale = Math.max(1, TARGET_CANVAS_PX / Math.max(config.areaWidth, config.areaHeight));
  scaleRef.current = scale;
  const px = (m: number) => m * scale;
  const viewW = px(config.areaWidth);
  const viewH = px(config.areaHeight);
  const radioRangeM = maxRangeM(rf);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    canvas.width = Math.round(viewW * dpr);
    canvas.height = Math.round(viewH * dpr);
    canvas.style.width = `${viewW}px`;
    canvas.style.height = `${viewH}px`;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    ctx.fillStyle = "#0b0f14";
    ctx.fillRect(0, 0, viewW, viewH);

    // 10 m grid
    ctx.strokeStyle = "#1e2a3a";
    ctx.lineWidth = 0.5;
    for (let m = 0; m <= config.areaWidth; m += 10) {
      ctx.beginPath();
      ctx.moveTo(px(m), 0);
      ctx.lineTo(px(m), viewH);
      ctx.stroke();
    }
    for (let m = 0; m <= config.areaHeight; m += 10) {
      ctx.beginPath();
      ctx.moveTo(0, px(m));
      ctx.lineTo(viewW, px(m));
      ctx.stroke();
    }

    // Buildings / obstacles that attenuate links
    for (const o of config.obstacles) {
      ctx.fillStyle = "rgba(120, 130, 150, 0.16)";
      ctx.strokeStyle = "rgba(150, 165, 190, 0.45)";
      ctx.lineWidth = 1;
      ctx.fillRect(px(o.x), px(o.y), px(o.w), px(o.h));
      ctx.strokeRect(px(o.x), px(o.y), px(o.w), px(o.h));
      ctx.fillStyle = "rgba(190, 205, 225, 0.55)";
      ctx.font = "9px Inter, sans-serif";
      ctx.fillText(o.label, px(o.x) + 3, px(o.y) + 11);
    }

    if (showRanges) {
      // Honest radio range: derived from tx power and RX sensitivity, not a
      // hard-coded circle that disagrees with the link model.
      for (const node of nodes) {
        if (!node.isOnline) continue;
        ctx.beginPath();
        ctx.arc(px(node.pos.x), px(node.pos.y), px(radioRangeM), 0, Math.PI * 2);
        ctx.fillStyle =
          node.role === "SUPER" ? "rgba(182, 255, 74, 0.05)" : "rgba(255, 184, 77, 0.035)";
        ctx.fill();
        ctx.strokeStyle =
          node.role === "SUPER" ? "rgba(182, 255, 74, 0.18)" : "rgba(255, 184, 77, 0.12)";
        ctx.lineWidth = 0.6;
        ctx.stroke();
      }
    }

    if (showLinks) {
      for (let i = 0; i < nodes.length; i++) {
        if (!nodes[i].isOnline) continue;
        for (let j = i + 1; j < nodes.length; j++) {
          if (!nodes[j].isOnline) continue;
          if (!canReach(nodes[i], nodes[j], rf)) continue;
          const q = normRssi(rssiModel(nodes[i], nodes[j], rf));
          const isSuperLink = nodes[i].role === "SUPER" || nodes[j].role === "SUPER";
          ctx.strokeStyle = isSuperLink
            ? `rgba(182, 255, 74, ${q * 0.35})`
            : `rgba(77, 224, 255, ${q * 0.18})`;
          ctx.lineWidth = isSuperLink ? 1.2 : 0.6;
          ctx.beginPath();
          ctx.moveTo(px(nodes[i].pos.x), px(nodes[i].pos.y));
          ctx.lineTo(px(nodes[j].pos.x), px(nodes[j].pos.y));
          ctx.stroke();
        }
      }
    }

    for (const node of nodes) {
      const isSelected = node.id === selectedId;
      const cx = px(node.pos.x);
      const cy = px(node.pos.y);
      const radius = node.role === "SUPER" ? 9 : 7;
      const color = !node.isOnline ? "#3a4a5a" : node.role === "SUPER" ? "#b6ff4a" : "#4de0ff";

      if (node.isOnline && (node.role === "SUPER" || isSelected)) {
        ctx.beginPath();
        ctx.arc(cx, cy, radius + 6, 0, Math.PI * 2);
        ctx.strokeStyle = node.role === "SUPER" ? "rgba(182,255,74,0.3)" : "rgba(77,224,255,0.4)";
        ctx.lineWidth = 2;
        ctx.stroke();
      }

      ctx.beginPath();
      ctx.arc(cx, cy, radius, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.strokeStyle = isSelected ? "#ffffff" : "rgba(255,255,255,0.2)";
      ctx.lineWidth = isSelected ? 2.5 : 1;
      ctx.stroke();

      if (node.isOnline) {
        const battW = 16;
        const battH = 3;
        const bx = cx - battW / 2;
        const by = cy + radius + 4;
        ctx.fillStyle = "#1e2a3a";
        ctx.fillRect(bx, by, battW, battH);
        ctx.fillStyle = node.battery > 0.5 ? "#b6ff4a" : node.battery > 0.25 ? "#ffb84d" : "#ff4d6d";
        ctx.fillRect(bx, by, battW * node.battery, battH);
        if (node.charging) {
          ctx.fillStyle = "#ffb84d";
          ctx.font = "8px sans-serif";
          ctx.fillText("\u26A1", cx + radius + 2, cy - radius);
        }
        if (node.oppQueue.length > 0) {
          ctx.fillStyle = "#ff4d6d";
          ctx.font = "8px sans-serif";
          ctx.fillText(`Q${node.oppQueue.length}`, cx - radius - 12, cy - radius);
        }
      } else {
        ctx.fillStyle = "#5a6a7a";
        ctx.font = "9px sans-serif";
        ctx.fillText("\u2715", cx - 3, cy + 3);
      }

      if (isSelected || node.role === "SUPER") {
        ctx.fillStyle = "#eaf2ff";
        ctx.font = "9px Inter, sans-serif";
        ctx.textAlign = "center";
        ctx.fillText(node.name, cx, cy - radius - 6);
        ctx.textAlign = "start";
      }
    }
  }, [nodes, config, rf, selectedId, showLinks, showRanges, scale, viewW, viewH, radioRangeM, frame]);

  const handleClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = (e.clientX - rect.left) / scaleRef.current;
    const y = (e.clientY - rect.top) / scaleRef.current;

    let closest: MeshNode | null = null;
    let closestDist = 6; // metres
    for (const node of nodes) {
      const d = Math.sqrt((node.pos.x - x) ** 2 + (node.pos.y - y) ** 2);
      if (d < closestDist) {
        closestDist = d;
        closest = node;
      }
    }
    if (closest) onSelect(closest.id);
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, alignItems: "center" }}>
      <canvas
        ref={canvasRef}
        onClick={handleClick}
        style={{ borderRadius: 12, border: "1px solid #1e2a3a", cursor: "pointer", display: "block" }}
      />
      <div style={{ fontSize: 10, color: "#5a6a7a" }}>
        {config.areaWidth}×{config.areaHeight} m · radio range ≈{radioRangeM.toFixed(0)} m ·
        grid 10 m
      </div>
    </div>
  );
}
