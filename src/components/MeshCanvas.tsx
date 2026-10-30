import { useEffect, useRef } from "react";
import type { MeshNode } from "../types";
import type { SimConfig } from "../simulation";
import type { RfParams } from "../rf";
import { canReach, maxRangeM, radioComponents, rssiModel, normRssi } from "../rf";

/**
 * Ring colours for the components of a split network, largest first.
 *
 * The largest component gets the dimmest colour on purpose: when a crowd splits 35/25 the
 * interesting half is the smaller one, and a palette that made the biggest piece the loudest
 * would put the emphasis where nothing is wrong. Distinct hues rather than shades, because the
 * point is to see at a glance which phones cannot hear which.
 */
const COMPONENT_COLORS = [
  "rgba(150,165,185,0.55)",
  "rgba(255,123,114,0.95)",
  "rgba(255,214,102,0.95)",
  "rgba(182,255,74,0.9)",
  "rgba(139,125,255,0.95)",
  "rgba(77,224,255,0.95)",
];

interface Props {
  nodes: MeshNode[];
  config: SimConfig;
  rf: RfParams;
  selectedId: string | null;
  onSelect: (id: string) => void;
  showLinks: boolean;
  showRanges: boolean;
  /** Ordered node ids of the route being traced (originator first), drawn as a
   *  highlighted polyline with a hop number on each segment. */
  traceIds?: string[];
  /** Bumped by the parent on every simulation update to trigger a redraw. */
  frame: number;
}

const TARGET_CANVAS_PX = 640;

export function MeshCanvas({ nodes, config, rf, selectedId, onSelect, showLinks, showRanges, traceIds, frame }: Props) {
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

    // The traced route, drawn over the link graph and under the nodes so the
    // hop markers stay readable (roadmap Phase 4: "via 2 nodes • SUPER Amir").
    if (traceIds && traceIds.length > 1) {
      const byId = new Map(nodes.map((n) => [n.id, n]));
      const pts: { x: number; y: number }[] = [];
      for (const id of traceIds) {
        const n = byId.get(id);
        if (n) pts.push({ x: px(n.pos.x), y: px(n.pos.y) });
      }
      ctx.save();
      ctx.strokeStyle = "rgba(255, 214, 102, 0.95)";
      ctx.lineWidth = 2.4;
      ctx.shadowColor = "rgba(255, 214, 102, 0.55)";
      ctx.shadowBlur = 9;
      ctx.beginPath();
      ctx.moveTo(pts[0].x, pts[0].y);
      for (const p of pts.slice(1)) ctx.lineTo(p.x, p.y);
      ctx.stroke();
      ctx.restore();

      ctx.font = "9px Inter, sans-serif";
      ctx.textAlign = "center";
      for (let i = 1; i < pts.length; i++) {
        const mx = (pts[i - 1].x + pts[i].x) / 2;
        const my = (pts[i - 1].y + pts[i].y) / 2;
        ctx.fillStyle = "rgba(11, 15, 20, 0.9)";
        ctx.beginPath();
        ctx.arc(mx, my, 7, 0, Math.PI * 2);
        ctx.fill();
        ctx.strokeStyle = "rgba(255, 214, 102, 0.9)";
        ctx.lineWidth = 1;
        ctx.stroke();
        ctx.fillStyle = "#ffd666";
        ctx.fillText(`${i}`, mx, my + 3);
      }
      ctx.textAlign = "start";
    }

    // docs/06 §24.10: a 60-node crowd splits and re-joins inside a measurement window, and
    // broadcast reach reads as two modes depending on how much of the window was spent split.
    // The status bar reports the share; this draws which nodes are on which side, because
    // "connected 49% of the window" does not tell you that the phone being watched is in the
    // piece that cannot hear the sender. Drawn only when there is a split, so a healthy
    // network looks exactly as it did before.
    const components = radioComponents(nodes, rf);
    const split = components.length > 1;
    const componentOf = new Map<string, number>();
    if (split) {
      components.forEach((component, index) => {
        for (const id of component) componentOf.set(id, index);
      });
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

      if (split) {
        // Dashed and outside the role ring, so it reads as a boundary rather than as a role.
        const index = componentOf.get(node.id) ?? 0;
        ctx.beginPath();
        ctx.arc(cx, cy, radius + 12, 0, Math.PI * 2);
        ctx.strokeStyle = COMPONENT_COLORS[index % COMPONENT_COLORS.length];
        ctx.lineWidth = 2;
        ctx.setLineDash([3, 3]);
        ctx.stroke();
        ctx.setLineDash([]);
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
  }, [nodes, config, rf, selectedId, showLinks, showRanges, traceIds, scale, viewW, viewH, radioRangeM, frame]);

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
