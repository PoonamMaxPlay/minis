package com.loopit.minis.camera

import java.util.concurrent.atomic.AtomicReference

/**
 * Session state machine: idle → preview → recording → paused → stopped → finalized.
 *
 * Transitions are guarded; illegal transitions return false. Listeners are notified
 * on the calling thread (callers can hop threads if needed).
 */
class CameraSession {
    enum class State { IDLE, PREVIEW, RECORDING, PAUSED, STOPPED, FINALIZED, ERROR }

    fun interface Listener {
        fun onStateChanged(prev: State, next: State, code: String?, message: String?)
    }

    private val current = AtomicReference(State.IDLE)
    private val listeners = mutableListOf<Listener>()

    val state: State get() = current.get()

    fun addListener(l: Listener) { synchronized(listeners) { listeners.add(l) } }
    fun removeListener(l: Listener) { synchronized(listeners) { listeners.remove(l) } }

    @Synchronized
    fun transition(next: State, code: String? = null, message: String? = null): Boolean {
        val prev = current.get()
        if (!isLegal(prev, next)) return false
        current.set(next)
        val snapshot = synchronized(listeners) { listeners.toList() }
        snapshot.forEach { it.onStateChanged(prev, next, code, message) }
        return true
    }

    fun error(code: String, message: String?) {
        val prev = current.get()
        current.set(State.ERROR)
        val snapshot = synchronized(listeners) { listeners.toList() }
        snapshot.forEach { it.onStateChanged(prev, State.ERROR, code, message) }
    }

    /** Emit an out-of-band info event (e.g. timeLapseFinalized) without state transition. */
    fun emitInfo(code: String, message: String?) {
        val cur = current.get()
        val snapshot = synchronized(listeners) { listeners.toList() }
        snapshot.forEach { it.onStateChanged(cur, cur, code, message) }
    }

    private fun isLegal(prev: State, next: State): Boolean = when (prev) {
        State.IDLE -> next == State.PREVIEW || next == State.ERROR
        State.PREVIEW -> next == State.RECORDING || next == State.IDLE || next == State.ERROR
        State.RECORDING -> next == State.PAUSED || next == State.STOPPED || next == State.ERROR
        State.PAUSED -> next == State.RECORDING || next == State.STOPPED || next == State.ERROR
        State.STOPPED -> next == State.FINALIZED || next == State.PREVIEW || next == State.ERROR
        State.FINALIZED -> next == State.PREVIEW || next == State.IDLE
        State.ERROR -> next == State.IDLE || next == State.PREVIEW
    }
}
