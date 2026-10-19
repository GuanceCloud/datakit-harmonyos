import { ReplayControlVectors } from './ReplayControlVectors';

export type ReplayPopupArrowSide = 'top' | 'bottom' | 'left' | 'right';
export interface ReplayPopupBody { x: number; y: number; width: number; height: number; }

/** Native message bubbles paint their rounded outline outside the Column's generic border fields. */
export class ReplayOverlayVectors {
  public static popup(width: number, height: number, body: ReplayPopupBody, color: string,
    side: ReplayPopupArrowSide = 'top'): string {
    const x = body.x, y = body.y, right = x + body.width, bottom = y + body.height;
    const radius = Math.min(20, body.width / 2, body.height / 2);
    let arrow: string;
    const cx = x + body.width / 2, cy = y + body.height / 2;
    if (side === 'bottom') arrow = `M${cx - 8} ${bottom - 1}L${cx - 2} ${Math.min(height, bottom + 6)}Q${cx} ${height} ${cx + 2} ${Math.min(height, bottom + 6)}L${cx + 8} ${bottom - 1}Z`;
    else if (side === 'left') arrow = `M${x + 1} ${cy - 8}L${Math.max(0, x - 6)} ${cy - 2}Q0 ${cy} ${Math.max(0, x - 6)} ${cy + 2}L${x + 1} ${cy + 8}Z`;
    else if (side === 'right') arrow = `M${right - 1} ${cy - 8}L${Math.min(width, right + 6)} ${cy - 2}Q${width} ${cy} ${Math.min(width, right + 6)} ${cy + 2}L${right - 1} ${cy + 8}Z`;
    else arrow = `M${cx - 8} ${y + 1}L${cx - 2} ${Math.max(0, y - 6)}Q${cx} 0 ${cx + 2} ${Math.max(0, y - 6)}L${cx + 8} ${y + 1}Z`;
    return ReplayControlVectors.document(width, height,
      `<rect x="${x}" y="${y}" width="${body.width}" height="${body.height}" rx="${radius}" fill="${color}"/><path d="${arrow}" fill="${color}"/>`);
  }
}
