package com.clipyclone.nativeandroid.sync

import android.os.SystemClock
import kotlinx.coroutines.*
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.Collections
import java.util.concurrent.atomic.AtomicInteger

 data class LocalIPv4(val interfaceName: String, val address: String)
data class DiscoveryProgress(val running: Boolean = false, val completed: Int = 0, val total: Int = 0)
data class DiscoveryTarget(val host: String, val port: Int, val peerId: String?, val reason: String)

object NativeDiscovery {
    fun localAddresses(): List<LocalIPv4> = try {
        Collections.list(NetworkInterface.getNetworkInterfaces()).filter { it.isUp && !it.isLoopback }.flatMap { iface ->
            Collections.list(iface.inetAddresses).filterIsInstance<Inet4Address>()
                .filter { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                .mapNotNull { address -> address.hostAddress?.takeIf(::isLanAddress)?.let { LocalIPv4(iface.name, it) } }
        }.sortedBy { if (Regex("^(tun|utun|tap|wg|ppp)").containsMatchIn(it.interfaceName)) 1 else 0 }
    } catch (_: Exception) { emptyList() }
    fun isLanAddress(ip: String): Boolean {
        if (!validIPv4(ip)) return false
        val p = ip.split('.').map(String::toInt)
        return p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && p[1] in 16..31) || (p[0] == 169 && p[1] == 254)
    }
    fun plan(settings: SyncSettings, endpoints: List<PeerEndpoint>, manual: List<String>, local: List<LocalIPv4>,
             connected: List<LanPeer>, full: Boolean, explicit: Boolean): List<DiscoveryTarget> {
        val targets = linkedMapOf<String, DiscoveryTarget>()
        fun add(target: DiscoveryTarget) {
            if (target.port !in 1..65535 || target.host.startsWith("relay:") || target.host.isEmpty()) return
            targets.putIfAbsent("${target.host}:${target.port}", target)
        }
        endpoints.filter { it.peerId != settings.peerId && (explicit || it.peerId in settings.authorizedPeers) }.forEach {
            add(DiscoveryTarget(it.host, it.port, it.peerId, if (explicit) "scan" else "cache"))
        }
        manual.forEach { entry ->
            val parts = entry.split(':')
            val port = parts.getOrNull(1)?.toIntOrNull() ?: settings.port
            val id = connected.firstOrNull { it.host == parts[0] }?.peerId
                ?: endpoints.firstOrNull { it.host == parts[0] && it.port == port }?.peerId
            if (explicit || id in settings.authorizedPeers) add(DiscoveryTarget(parts[0], port, id, if (explicit) "scan" else "manual"))
        }
        if (full) {
            val addresses = local.filterNot { Regex("^(tun|utun|tap|wg|ppp|rmnet|ccmni|pdp_ip)").containsMatchIn(it.interfaceName) }
                .map { it.address }.filter { validIPv4(it) && isLanAddress(it) }.distinct()
            val prefixes = addresses.map { it.substringBeforeLast('.') }.distinct().take(2)
            val excluded = addresses.toSet() + connected.map { it.host }
            prefixes.forEach { prefix -> (1..254).forEach { suffix ->
                val host = "$prefix.$suffix"
                if (host !in excluded) add(DiscoveryTarget(host, settings.port, null, "scan"))
            } }
        }
        return targets.values.toList()
    }
    suspend fun scan(targets: List<DiscoveryTarget>, concurrency: Int = 64, current: () -> Boolean,
                     progress: (Int, Int) -> Unit, probe: suspend (DiscoveryTarget) -> Unit) = coroutineScope {
        require(concurrency > 0)
        val index = AtomicInteger(); val completed = AtomicInteger(); val progressLock = Any()
        if (!current()) return@coroutineScope
        progress(0, targets.size)
        List(minOf(concurrency, targets.size)) {
            launch {
                while (current()) {
                    val next = index.getAndIncrement()
                    if (next >= targets.size) break
                    probe(targets[next])
                    synchronized(progressLock) { if (current()) progress(completed.incrementAndGet(), targets.size) }
                }
            }
        }.joinAll()
    }
}

/** Same coalescing and manual/automatic cooldowns as DiscoveryRefreshCoordinator; no timer. */
class DiscoveryRefreshCoordinator(private val scope: CoroutineScope, private val now: () -> Long = SystemClock::elapsedRealtime) {
    private val lock = Any()
    private var active: Deferred<Unit>? = null
    private var lastFinished: Long? = null
    private var fullRequested = false
    private var generation = 0L
    suspend fun refresh(automatic: Boolean, hasPeers: () -> Boolean, scan: suspend (Boolean) -> Unit) {
        val task = synchronized(lock) {
            active?.also { if (!automatic) fullRequested = true } ?: run {
                if (automatic && hasPeers()) return
                val last = lastFinished
                if (last != null && now() - last < if (automatic) 30000 else 3000) return
                val epoch = generation
                fullRequested = !automatic
                scope.async(start = CoroutineStart.LAZY) {
                    try {
                        if (synchronized(lock) { epoch == generation && !fullRequested }) scan(false)
                        if (synchronized(lock) { epoch == generation && (fullRequested || !hasPeers()) }) scan(true)
                    } finally {
                        synchronized(lock) { if (epoch == generation) { lastFinished = now(); active = null } }
                    }
                }.also { active = it }
            }
        }
        task.start(); task.await()
    }
    fun reset() = synchronized(lock) {
        generation++; active?.cancel(); active = null; lastFinished = null; fullRequested = false
    }
}
