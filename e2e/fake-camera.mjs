// Writes a tiny fake camera clip (Y4M, 160x120 @ 10 fps) for Chrome's
// --use-file-for-fake-video-capture. The default fake camera is 720p/30fps;
// several tabs decoding and drawing that in software (no GPU in CI) starve
// the machine so badly that a third tab can take over a minute to start.
import { writeFileSync } from 'node:fs';

export function writeFakeCamera(path) {
  const width = 160;
  const height = 120;
  const frames = 20;
  const parts = [Buffer.from(`YUV4MPEG2 W${width} H${height} F10:1 Ip A1:1 C420jpeg\n`)];
  for (let f = 0; f < frames; f++) {
    parts.push(Buffer.from('FRAME\n'));
    const y = Buffer.alloc(width * height);
    for (let row = 0; row < height; row++) {
      for (let col = 0; col < width; col++) y[row * width + col] = (col + row + f * 8) & 0xff;
    }
    parts.push(y, Buffer.alloc((width * height) / 4, 128), Buffer.alloc((width * height) / 4, 128));
  }
  writeFileSync(path, Buffer.concat(parts));
}
