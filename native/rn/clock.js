// Installed as a Metro polyfill so React Native, React and any scene code capture the virtual
// clock instead of wall time. A scene reading the clock must bake identically on every run.
;(function () {
  var EPOCH = 1735689600000
  var now = 0
  var queue = []
  var nextId = 1
  var seed = 0x9e3779b9

  var RealDate = global.Date

  if (!global.performance) global.performance = {}
  global.performance.now = function () {
    return now
  }

  global.Math.random = function () {
    seed |= 0
    seed = (seed + 0x6d2b79f5) | 0
    var t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }

  var VirtualDate = function () {
    if (arguments.length === 0) return new RealDate(EPOCH + now)
    return new (Function.prototype.bind.apply(RealDate, [null].concat(Array.prototype.slice.call(arguments))))()
  }
  VirtualDate.prototype = RealDate.prototype
  VirtualDate.now = function () {
    return EPOCH + now
  }
  VirtualDate.parse = RealDate.parse
  VirtualDate.UTC = RealDate.UTC
  global.Date = VirtualDate

  global.requestAnimationFrame = function (callback) {
    var id = nextId++
    queue.push([id, callback])
    return id
  }
  global.cancelAnimationFrame = function (id) {
    queue = queue.filter(function (entry) {
      return entry[0] !== id
    })
  }

  global.__clock = {
    seedRandom: function (value) {
      seed = (value | 0) || 0x9e3779b9
    },
    set: function (ms) {
      now = ms
    },
    now: function () {
      return now
    },
    // ponytail: one flush per seek — correct for sequential baking, where each rAF chain advances
    // one step per frame. Random-access seeking would need a replay from zero; add it if scrubbing needs it.
    flush: function () {
      var due = queue
      queue = []
      for (var i = 0; i < due.length; i++) {
        try {
          due[i][1](now)
        } catch (error) {
          if (global.__recordError) global.__recordError(error)
        }
      }
      return due.length
    },
  }
})()
