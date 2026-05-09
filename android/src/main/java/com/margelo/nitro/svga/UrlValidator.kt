package com.margelo.nitro.svga

import java.net.URI
import java.net.URISyntaxException

internal object UrlValidator {

  enum class Kind { REMOTE, LOCAL_FILE, BUNDLED_ASSET }

  data class Resolved(val kind: Kind, val value: String)

  fun resolve(source: String): Resolved? {
    val trimmed = source.trim()
    if (trimmed.isEmpty()) return null

    val uri = parse(trimmed) ?: return null
    val scheme = uri.scheme?.lowercase()

    if (scheme == "http" || scheme == "https") {
      val host = uri.host
      if (host.isNullOrBlank()) return null
      val path = uri.path
      if (path != null && pathContainsTraversal(path)) return null
      return Resolved(Kind.REMOTE, trimmed)
    }
    if (scheme == "asset") {
      val name = trimmed.removePrefix("asset://")
      if (pathContainsTraversal(name)) return null
      return Resolved(Kind.BUNDLED_ASSET, name)
    }
    if (scheme == "file") {
      val path = uri.path ?: return null
      if (pathContainsTraversal(path)) return null
      return Resolved(Kind.LOCAL_FILE, path)
    }
    if (scheme == null && trimmed.startsWith("/")) {
      if (pathContainsTraversal(trimmed)) return null
      return Resolved(Kind.LOCAL_FILE, trimmed)
    }
    return null
  }

  private fun pathContainsTraversal(path: String): Boolean {
    return path.split('/').any { it == ".." }
  }

  private fun parse(value: String): URI? {
    return try {
      URI(value)
    } catch (_: URISyntaxException) {
      null
    }
  }
}
