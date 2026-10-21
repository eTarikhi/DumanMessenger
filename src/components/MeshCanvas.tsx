import { useEffect, useRef } from "react";
import type { MeshNode } from "../types";
import type { SimConfig } from "../simulation";
import { rssiModel, canReach } from "../rf";

interface Props {
  nodes: MeshNode[];
  config: SimConfig;
  selectedId: string | null;
  onSelect: (id: string) => void;
  showLinks: boolean;
  showRanges: boolean;
}

export function MeshCanvas({ nodes, config, selectedId, onSelect, showLinks, showRanges }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    canvas.width = config.areaWidth * dpr;
    canvas.height = config.areaHeight * dpr;
    canvas.style.width = `${config.areaWidth}px`;
    canvas.style.height = `${config.areaHeight}px`;
    ctx.scale(dpr, dpr);

    ctx.fillStyle = "#0b0f14";
    ctx.fillRect(0, 0, config.areaWidth, config.areaHeight);

    const grid = 40;
    ctx.strokeStyle = "#1e2a3a";
    ctx.lineWidth = 0.5;
    for (let x = 0; x <= config.areaWidth; x += grid) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, config.areaHeight);
      ctx.stroke();
    }
    for (let y = 0; y <= config.areaHeight; y += grid) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(config.areaWidth, y);
      ctx.stroke();
    }

    if (showRanges) {
      for (const node of nodes) {
        if (!node.isOnline) continue;
        ctx.beginPath();
        ctx.arc(node.pos.x, node.pos.y, 100, 0, Math.PI * 2);
        ctx.fillStyle = node.role === "SUPER"
          ? "rgba(182, 255, 74, 0.04)"
          : "rgba(255, 184, 77, 0.03)";
        ctx.fill();
      }
    }

    if (showLinks) {
      for (let i = 0; i < nodes.length; i++) {
        if (!nodes[i].isOnline) continue;
        for (let j = i + 1; j < nodes.length; j++) {
          if (!nodes[j].isOnline) continue;
          if (!canReach(nodes[i], nodes[j])) continue;
          const rssi = rssiModel(nodes[i], nodes[j]);
          const quality = Math.max(0, Math.min(1, (rssi + 100) / 70));
          const isSuperLink = nodes[i].role === "SUPER" || nodes[j].role === "SUPER";
          ctx.strokeStyle = isSuperLink
            ? `rgba(182, 255, 74, ${quality * 0.35})`
            : `rgba(77, 224, 255, ${quality * 0.18})`;
          ctx.lineWidth = isSuperLink ? 1.2 : 0.6;
          ctx.beginPath();
          ctx.moveTo(nodes[i].pos.x, nodes[i].pos.y);
          ctx.lineTo(nodes[j].pos.x, nodes[j].pos.y);
          ctx.stroke();
        }
      }
    }

    for (const node of nodes) {
      const isSelected = node.id === selectedId;
      const radius = node.role === "SUPER" ? 9 : 7;
      const color = !node.isOnline
        ? "#3a4a5a"
        : node.role === "SUPER"
        ? "#b6ff4a"
        : "#4de0ff";

      if (node.isOnline && (node.role === "SUPER" || isSelected)) {
        ctx.beginPath();
        ctx.arc(node.pos.x, node.pos.y, radius + 6, 0, Math.PI * 2);
        ctx.strokeStyle = node.role === "SUPER" ? "rgba(182,255,74,0.3)" : "rgba(77,224,255,0.4)";
        ctx.lineWidth = 2;
        ctx.stroke();
      }

      ctx.beginPath();
      ctx.arc(node.pos.x, node.pos.y, radius, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.strokeStyle = isSelected ? "#ffffff" : "rgba(255,255,255,0.2)";
      ctx.lineWidth = isSelected ? 2.5 : 1;
      ctx.stroke();

      if (node.isOnline) {
        const battW = 16;
        const battH = 3;
        const bx = node.pos.x - battW / 2;
        const by = node.pos.y + radius + 4;
        ctx.fillStyle = "#1e2a3a";
        ctx.fillRect(bx, by, battW, battH);
        const battColor = node.battery > 0.5 ? "#b6ff4a" : node.battery > 0.25 ? "#ffb84d" : "#ff4d6d";
        ctx.fillStyle = battColor;
        ctx.fillRect(bx, by, battW * node.battery, battH);

        if (node.charging) {
          ctx.fillStyle = "#ffb84d";
          ctx.font = "8px sans-serif";
          ctx.fillText("⚡", node.pos.x + radius + 2, node.pos.y - radius);
        }
      } else {
        ctx.fillStyle = "#5a6a7a";
        ctx.font = "9px sans-serif";
        ctx.fillText("✕", node.pos.x - 3, node.pos.y + 3);
      }

      if (isSelected || node.role === "SUPER") {
        ctx.fillStyle = "#eaf2ff";
        ctx.font = "9px Inter, sans-serif";
        ctx.textAlign = "center";
        ctx.fillText(node.name, node.pos.x, node.pos.y - radius - 6);
        ctx.textAlign = "start";
      }
    }
  }, [nodes, config, selectedId, showLinks, showRanges]);

  const handleClick = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    let closest: MeshNode | null = null;
    let closestDist = 20;
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
    <canvas
      ref={canvasRef}
      onClick={handleClick}
      style={{
        borderRadius: 12,
        border: "1px solid #1e2a3a",
        cursor: "pointer",
        display: "block",
      }}
    />
  );
}
