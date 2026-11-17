import Foundation
import os

/// 线程安全的立体声环形缓冲。网络线程写入，音频渲染线程读出。
/// - 缓冲不足 target 时先攒着（输出静音），攒够了再放，避免断断续续。
/// - 缓冲超过 max（电脑时钟比手机快、或网络突发）时丢掉多余的旧数据，把延迟拉回 target。
final class RingBuffer {
    private let capacity: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var readIdx = 0
    private var count = 0
    private var buffering = true
    private var targetFrames: Int
    private var maxFrames: Int
    private var _underruns = 0
    private var _drops = 0
    private var _renderCalls = 0
    private var _peak: Float = 0

    /// 自上次读取以来收到的声音峰值（0~1），给音量动画用
    func takePeak() -> Float {
        os_unfair_lock_lock(lock)
        defer { _peak = 0; os_unfair_lock_unlock(lock) }
        return _peak
    }

    init(capacityFrames: Int, targetFrames: Int) {
        capacity = capacityFrames
        left = .allocate(capacity: capacityFrames)
        right = .allocate(capacity: capacityFrames)
        left.initialize(repeating: 0, count: capacityFrames)
        right.initialize(repeating: 0, count: capacityFrames)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        self.targetFrames = targetFrames
        self.maxFrames = targetFrames * 3
    }

    deinit {
        left.deallocate()
        right.deallocate()
        lock.deallocate()
    }

    /// headroom：在目标之上还能多存多少（网络卡完一下子涌来的数据先存着，不急着丢）
    func setTarget(frames: Int, headroom: Int) {
        os_unfair_lock_lock(lock)
        targetFrames = max(64, min(frames, capacity / 3))
        maxFrames = min(capacity - 1, targetFrames + max(headroom, targetFrames))
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        readIdx = 0
        count = 0
        buffering = true
        os_unfair_lock_unlock(lock)
    }

    /// 写入 16 位交错立体声
    func write(interleaved src: UnsafePointer<Int16>, frames: Int) {
        os_unfair_lock_lock(lock)
        for i in 0..<frames {
            if count == capacity {
                readIdx = (readIdx + 1) % capacity
                count -= 1
            }
            let w = (readIdx + count) % capacity
            let l = Float(src[2 * i]) / 32768.0
            let r = Float(src[2 * i + 1]) / 32768.0
            left[w] = l
            right[w] = r
            let a = max(abs(l), abs(r))
            if a > _peak { _peak = a }
            count += 1
        }
        // 不论是否在攒缓冲，都不让积压超过上限（播放卡住时也不会攒出几秒延迟）
        if count > maxFrames {
            let drop = count - targetFrames
            readIdx = (readIdx + drop) % capacity
            count -= drop
            _drops += 1
        }
        os_unfair_lock_unlock(lock)
    }

    /// 渲染线程调用
    func read(left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>, frames: Int) {
        os_unfair_lock_lock(lock)
        _renderCalls &+= 1
        if buffering {
            if count >= targetFrames {
                buffering = false
            } else {
                os_unfair_lock_unlock(lock)
                outL.update(repeating: 0, count: frames)
                outR.update(repeating: 0, count: frames)
                return
            }
        }
        let n = min(frames, count)
        var copied = 0
        while copied < n {
            let chunk = min(n - copied, capacity - readIdx)
            (outL + copied).update(from: left + readIdx, count: chunk)
            (outR + copied).update(from: right + readIdx, count: chunk)
            readIdx = (readIdx + chunk) % capacity
            copied += chunk
        }
        count -= n
        if n < frames {
            buffering = true
            _underruns += 1
        }
        os_unfair_lock_unlock(lock)
        if n < frames {
            (outL + n).update(repeating: 0, count: frames - n)
            (outR + n).update(repeating: 0, count: frames - n)
        }
    }

    struct Stats { let frames: Int; let underruns: Int; let drops: Int; let renderCalls: Int }

    var stats: Stats {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Stats(frames: count, underruns: _underruns, drops: _drops, renderCalls: _renderCalls)
    }
}
