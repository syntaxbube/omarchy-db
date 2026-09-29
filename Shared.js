.pragma library

// One copy of this file is shared by every widget instance (the bar exists
// once per monitor), so a delay alert is only sent once however many bars
// are showing the same train.

var sent = ({})

function claim(key) {
  if (!key || sent[key]) return false
  sent[key] = Date.now()
  prune()
  return true
}

// Forget alerts older than a day so the map does not grow forever.
function prune() {
  var cutoff = Date.now() - 24 * 3600 * 1000
  for (var k in sent) {
    if (sent[k] < cutoff) delete sent[k]
  }
}
