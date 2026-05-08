package com.garmiand.map

import java.net.Inet4Address
import java.net.NetworkInterface

object NetworkUtil {

    fun getLocalIp(): String? {
        return try {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress && !it.isLinkLocalAddress }
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }
}
