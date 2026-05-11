export function randomIntBetween(min, max) {
  return Math.floor(Math.random() * (max - min + 1) + min);
}

export function randomItem(arrayOfItems) {
  return arrayOfItems[Math.floor(Math.random() * arrayOfItems.length)];
}

export function findBetween(content, left, right) {
  let start = content.indexOf(left);
  if (start === -1) return "";
  start += left.length;
  const end = content.indexOf(right, start);
  if (end === -1) return "";
  return content.substring(start, end);
}
