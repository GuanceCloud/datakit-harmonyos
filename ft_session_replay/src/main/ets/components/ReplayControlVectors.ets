export interface ReplayVectorPoint { x: number; y: number; }
export interface ReplayVectorStop { color: string; offset: number; }

/** Analytic control paint, not component snapshots. SVG keeps curves crisp at any replay zoom. */
export class ReplayControlVectors {
  public static document(width: number, height: number, content: string): string {
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${ReplayControlVectors.metric(width)}" height="${ReplayControlVectors.metric(height)}" viewBox="0 0 ${ReplayControlVectors.metric(width)} ${ReplayControlVectors.metric(height)}">${content}</svg>`;
  }

  public static paint(color: string, property: string = 'fill'): string {
    return `${property}="${color.substring(0, 7)}" ${property}-opacity="${ReplayControlVectors.metric(parseInt(color.substring(7, 9), 16) / 255)}"`;
  }

  public static polygon(points: Array<ReplayVectorPoint>, color: string): string {
    return `<polygon points="${points.map((point): string => `${ReplayControlVectors.metric(point.x)},${ReplayControlVectors.metric(point.y)}`).join(' ')}" ${ReplayControlVectors.paint(color)}/>`;
  }

  public static path(points: Array<ReplayVectorPoint>, stroke: number, color: string): string {
    if (points.length < 2) return '';
    return `<path d="M${points.map((point): string => `${ReplayControlVectors.metric(point.x)} ${ReplayControlVectors.metric(point.y)}`).join('L')}" fill="none" ${ReplayControlVectors.paint(color, 'stroke')} stroke-width="${ReplayControlVectors.metric(stroke)}" stroke-linecap="round" stroke-linejoin="round"/>`;
  }

  public static arc(width: number, height: number, start: number, sweep: number, stroke: number,
    stops: Array<ReplayVectorStop>): string {
    const radius = Math.max(0, (Math.min(width, height) - stroke) / 2);
    const extent = Math.max(0, Math.min(360, sweep));
    if (radius <= 0 || extent <= 0 || stops.length === 0) return ReplayControlVectors.document(width, height, '');
    const point = (angle: number): ReplayVectorPoint => ({
      x: width / 2 + Math.sin(angle * Math.PI / 180) * radius,
      y: height / 2 - Math.cos(angle * Math.PI / 180) * radius });
    // Each sector is a true circular arc with a continuous local gradient.
    // This avoids both staircase silhouettes and visible solid-colour bands.
    const cuts: Array<number> = [0, 1];
    if (stops.length > 1) {
      const sectors = Math.max(1, Math.ceil(extent / 12));
      for (let index = 1; index < sectors; index++) cuts.push(index / sectors);
      for (const stop of stops) if (stop.offset > 0 && stop.offset < 1 && !cuts.includes(stop.offset)) cuts.push(stop.offset);
    } else if (extent === 360) cuts.push(0.5);
    cuts.sort((a, b): number => a - b);
    const uniformAlpha = stops.every((stop): boolean => stop.color.substring(7) === stops[0].color.substring(7));
    const opacity = uniformAlpha ? parseInt(stops[0].color.substring(7, 9), 16) / 255 : 1;
    const colors = uniformAlpha ? stops.map((stop): ReplayVectorStop => ({ color: stop.color.substring(0, 7) + 'FF', offset: stop.offset })) : stops;
    const overlap = uniformAlpha ? 0.25 : 0;
    let definitions = ''; let paths = '';
    for (let index = 1; index < cuts.length; index++) {
      const from = point(start + extent * cuts[index - 1] - (index > 1 ? overlap : 0));
      const to = point(start + extent * cuts[index] + (index < cuts.length - 1 ? overlap : 0));
      const first = ReplayControlVectors.color(colors, cuts[index - 1]);
      const last = ReplayControlVectors.color(colors, cuts[index]);
      const gradient = `g${index}`;
      definitions += `<linearGradient id="${gradient}" gradientUnits="userSpaceOnUse" x1="${ReplayControlVectors.metric(from.x)}" y1="${ReplayControlVectors.metric(from.y)}" x2="${ReplayControlVectors.metric(to.x)}" y2="${ReplayControlVectors.metric(to.y)}"><stop ${ReplayControlVectors.paint(first, 'stop-color').replace('stop-color-opacity', 'stop-opacity')} offset="0"/><stop ${ReplayControlVectors.paint(last, 'stop-color').replace('stop-color-opacity', 'stop-opacity')} offset="1"/></linearGradient>`;
      paths += `<path d="M${ReplayControlVectors.metric(from.x)} ${ReplayControlVectors.metric(from.y)}A${ReplayControlVectors.metric(radius)} ${ReplayControlVectors.metric(radius)} 0 ${extent * (cuts[index] - cuts[index - 1]) > 180 ? 1 : 0} 1 ${ReplayControlVectors.metric(to.x)} ${ReplayControlVectors.metric(to.y)}" fill="none" stroke="url(#${gradient})" stroke-width="${ReplayControlVectors.metric(stroke)}"/>`;
    }
    if (extent < 360) {
      for (const end of [0, 1]) {
        const position = point(start + extent * end);
        if (uniformAlpha) {
          paths += `<circle cx="${ReplayControlVectors.metric(position.x)}" cy="${ReplayControlVectors.metric(position.y)}" r="${ReplayControlVectors.metric(stroke / 2)}" ${ReplayControlVectors.paint(ReplayControlVectors.color(colors, end))}/>`;
          continue;
        }
        const angle = (start + extent * end) * Math.PI / 180;
        const nx = Math.sin(angle) * stroke / 2; const ny = -Math.cos(angle) * stroke / 2;
        // Only the outward semicircle is painted. A full dot over the stroke
        // would double the alpha of a translucent cap.
        paths += `<path d="M${ReplayControlVectors.metric(position.x + nx)} ${ReplayControlVectors.metric(position.y + ny)}A${ReplayControlVectors.metric(stroke / 2)} ${ReplayControlVectors.metric(stroke / 2)} 0 0 ${end} ${ReplayControlVectors.metric(position.x - nx)} ${ReplayControlVectors.metric(position.y - ny)}Z" ${ReplayControlVectors.paint(ReplayControlVectors.color(colors, end))}/>`;
      }
    }
    return ReplayControlVectors.document(width, height, `<defs>${definitions}</defs><g opacity="${ReplayControlVectors.metric(opacity)}">${paths}</g>`);
  }

  public static gradient(id: string, stops: Array<ReplayVectorStop>): string {
    return `<linearGradient id="${id}">${stops.map((stop): string => `<stop offset="${ReplayControlVectors.metric(Math.max(0, Math.min(1, stop.offset)))}" ${ReplayControlVectors.paint(stop.color, 'stop-color').replace('stop-color-opacity', 'stop-opacity')}/>`).join('')}</linearGradient>`;
  }

  public static shadow(svg: string, width: number, height: number, blur: number, x: number, y: number): string {
    const content = svg.substring(svg.indexOf('>') + 1, svg.lastIndexOf('</svg>'));
    return ReplayControlVectors.document(width, height,
      `<defs><filter id="shadow" x="-50%" y="-50%" width="200%" height="200%" color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="${ReplayControlVectors.metric(blur / 2)}"/></filter></defs><g transform="translate(${ReplayControlVectors.metric(x)} ${ReplayControlVectors.metric(y)})" opacity="0.35" filter="url(#shadow)">${content}</g>`);
  }

  private static color(stops: Array<ReplayVectorStop>, position: number): string {
    if (position <= stops[0].offset) return stops[0].color;
    for (let index = 1; index < stops.length; index++) {
      const a = stops[index - 1]; const b = stops[index];
      if (position > b.offset) continue;
      const fraction = b.offset > a.offset ? (position - a.offset) / (b.offset - a.offset) : 0;
      let result = '#';
      for (let channel = 1; channel < 9; channel += 2) result += Math.round(
        parseInt(a.color.substring(channel, channel + 2), 16) * (1 - fraction) +
        parseInt(b.color.substring(channel, channel + 2), 16) * fraction).toString(16).padStart(2, '0');
      return result.toUpperCase();
    }
    return stops[stops.length - 1].color;
  }

  private static metric(value: number): number { return Math.round(value * 10000) / 10000; }
}
