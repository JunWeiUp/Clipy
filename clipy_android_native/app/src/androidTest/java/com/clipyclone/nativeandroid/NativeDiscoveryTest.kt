package com.clipyclone.nativeandroid

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clipyclone.nativeandroid.sync.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class NativeDiscoveryTest {
    @Test fun scanPlanExcludesVpnAndSelfAndLimitsTwoLanSubnets() {
        val settings = SyncSettings("local", "Example", 5566, true, setOf("allowed"), emptySet())
        val endpoints = listOf(PeerEndpoint("allowed", "Allowed", "192.0.2.4", 5566, 0.0), PeerEndpoint("other", "Other", "192.0.2.5", 5566, 0.0))
        val interfaces = listOf(LocalIPv4("tun0", "10.8.0.2"), LocalIPv4("wlan0", "192.168.1.10"),
            LocalIPv4("wlan1", "192.168.2.10"), LocalIPv4("wlan2", "192.168.3.10"), LocalIPv4("rmnet0", "10.1.1.1"))
        val background = NativeDiscovery.plan(settings, endpoints, listOf("198.51.100.2:5566"), interfaces, emptyList(), false, false)
        assertEquals(listOf("192.0.2.4"), background.map { it.host })
        val explicit = NativeDiscovery.plan(settings, endpoints, listOf("192.0.2.4:5566"), interfaces, emptyList(), true, true)
        assertEquals(508, explicit.size)
        assertEquals(1, explicit.count { it.host == "192.0.2.4" })
        assertFalse(explicit.any { it.host == "192.168.1.10" || it.host.startsWith("10.") || it.host.startsWith("192.168.3.") })
    }
    @Test fun workerPoolBoundsConcurrencyAndProgressCountsCompletion() = runBlocking {
        val targets = (1..9).map { DiscoveryTarget("192.0.2.$it", 5566, null, "scan") }
        val active = AtomicInteger(); val peak = AtomicInteger(); val completed = AtomicInteger()
        NativeDiscovery.scan(targets, 3, { true }, { done, _ -> completed.set(done) }) {
            val count = active.incrementAndGet(); peak.updateAndGet { maxOf(it, count) }
            delay(10); active.decrementAndGet()
        }
        assertEquals(9, completed.get()); assertTrue(peak.get() <= 3)
    }
    @Test fun manualRefreshUpgradesAutomaticJobAndCooldownPreventsExtraScans() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        var now = 0L
        val coordinator = DiscoveryRefreshCoordinator(scope) { now }
        val started = CompletableDeferred<Unit>(); val resume = CompletableDeferred<Unit>()
        val scans = mutableListOf<Boolean>()
        try {
            val automatic = async { coordinator.refresh(true, { false }) { full -> scans += full; if (!full) { started.complete(Unit); resume.await() } } }
            started.await()
            val manual = async(start = CoroutineStart.UNDISPATCHED) { coordinator.refresh(false, { false }) { fail("Must join the first job") } }
            resume.complete(Unit); automatic.await(); manual.await()
            assertEquals(listOf(false, true), scans)
            coordinator.refresh(false, { false }) { fail("Cooldown should suppress refresh") }
            now = 4000
            coordinator.refresh(false, { false }) { scans += it }
            assertEquals(listOf(false, true, true), scans)
        } finally { coordinator.reset(); scope.cancel() }
    }
}
