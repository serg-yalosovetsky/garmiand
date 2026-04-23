package com.garmiand.domain

data class RoutePoint(
    val lat: Double,
    val lon: Double,
)

data class Marker(
    val id: String,
    val lat: Double,
    val lon: Double,
    val title: String,
)

data class RoutePackage(
    val routeId: String,
    val name: String,
    val points: List<RoutePoint>,
    val markers: List<Marker>,
)
