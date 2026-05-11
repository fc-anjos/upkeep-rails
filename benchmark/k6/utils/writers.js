export function isWriterVu(vuNumber, writerEvery, writerStartVu = 1) {
  const cadence = Math.max(1, Number.parseInt(writerEvery, 10) || 1);
  const startVu = Math.max(1, Number.parseInt(writerStartVu, 10) || 1);
  if (vuNumber < startVu) return false;
  return (vuNumber - startVu) % cadence === 0;
}
