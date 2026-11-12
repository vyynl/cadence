// WebAuthn ceremony driver (plan §7.9). Classic script: CSP is script-src
// 'self', there is no bundler, and no third-party code is loaded.
//
// The page provides one element with [data-passkeys], the JSON options from
// the server, and the endpoint to POST the result to. This script only drives
// the browser ceremony and transports base64url values; all verification is
// server-side.
(() => {
  "use strict"

  const root = document.querySelector("[data-passkeys]")
  if (!root) return

  const mode = root.dataset.mode === "register" ? "register" : "sign-in"
  const endpoint = root.dataset.endpoint
  const returnTo = root.dataset.returnTo || ""
  const form = root.querySelector("[data-passkey-form]")
  const button = root.querySelector("[data-passkey-submit]")
  const status = root.querySelector("[data-passkey-status]")
  const csrf = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

  const text = {
    working: "Waiting for your security key or passkey…",
    unavailable:
      "This browser does not support security keys or passkeys. Try a current browser or use another sign-in method.",
    cancelled:
      "The request was cancelled or timed out. Try again, and touch your security key when it blinks.",
    alreadyRegistered: "This security key or passkey is already registered on your account.",
    blocked:
      "The browser blocked the request because the site address does not match. Contact your administrator.",
    unsupported:
      "This browser or key does not support the required verification. Try a FIDO2 key or a passkey.",
    keyFull:
      "Your security key cannot store another passkey (it may be full). Remove an old passkey from the key or use another key.",
    interrupted: "The request was interrupted. Try again.",
    generic: "That key could not sign you in. Try again or use another sign-in method.",
    genericRegister:
      "That security key could not be added. Try again or use another sign-in method.",
  }

  let options
  try {
    options = JSON.parse(root.dataset.optionsJson || "{}")
  } catch (_error) {
    options = null
  }

  function setStatus(message, isError) {
    if (!status) return
    status.textContent = message
    status.classList.toggle("passkey-status-error", Boolean(isError))
  }

  function base64urlToBytes(value) {
    if (!value) return null
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/")
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4)
    const binary = window.atob(padded)
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i)
    return bytes
  }

  function bytesToBase64url(value) {
    if (!value) return null
    const bytes = value instanceof Uint8Array ? value : new Uint8Array(value)
    let binary = ""
    const chunkSize = 0x8000
    for (let offset = 0; offset < bytes.length; offset += chunkSize) {
      binary += String.fromCharCode.apply(null, bytes.subarray(offset, offset + chunkSize))
    }
    return window
      .btoa(binary)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "")
  }

  function toPublicKey() {
    const publicKey = { ...options }
    publicKey.challenge = base64urlToBytes(options.challenge)
    if (options.user) {
      publicKey.user = { ...options.user, id: base64urlToBytes(options.user.id) }
    }
    if (Array.isArray(options.excludeCredentials)) {
      publicKey.excludeCredentials = options.excludeCredentials.map((descriptor) => ({
        ...descriptor,
        id: base64urlToBytes(descriptor.id),
      }))
    }
    if (Array.isArray(options.allowCredentials)) {
      publicKey.allowCredentials = options.allowCredentials.map((descriptor) => ({
        ...descriptor,
        id: base64urlToBytes(descriptor.id),
      }))
    }
    return publicKey
  }

  function registrationPayload(credential) {
    const response = credential.response
    const labelInput = form ? form.querySelector("[name='label']") : null

    return {
      id: credential.id,
      rawId: bytesToBase64url(credential.rawId),
      type: credential.type,
      response: {
        attestationObject: bytesToBase64url(response.attestationObject),
        clientDataJSON: bytesToBase64url(response.clientDataJSON),
      },
      transports:
        typeof response.getTransports === "function" ? response.getTransports() : [],
      label: labelInput ? labelInput.value.trim() : "",
    }
  }

  function assertionPayload(credential) {
    const response = credential.response

    return {
      id: credential.id,
      rawId: bytesToBase64url(credential.rawId),
      type: credential.type,
      response: {
        authenticatorData: bytesToBase64url(response.authenticatorData),
        clientDataJSON: bytesToBase64url(response.clientDataJSON),
        signature: bytesToBase64url(response.signature),
        userHandle: response.userHandle ? bytesToBase64url(response.userHandle) : null,
      },
      return_to: returnTo,
    }
  }

  function browserErrorCopy(error) {
    const fallback = mode === "register" ? text.genericRegister : text.generic

    switch (error && error.name) {
      case "NotAllowedError":
        return text.cancelled
      case "InvalidStateError":
        return text.alreadyRegistered
      case "SecurityError":
        return text.blocked
      case "NotSupportedError":
        return text.unsupported
      case "ConstraintError":
        return text.keyFull
      case "AbortError":
        return text.interrupted
      default:
        return fallback
    }
  }

  async function submit(event) {
    event.preventDefault()

    if (!endpoint || !options || !window.PublicKeyCredential || !navigator.credentials) {
      setStatus(text.unavailable, true)
      return
    }

    if (button) button.disabled = true
    setStatus(text.working, false)

    try {
      const publicKey = toPublicKey()
      const credential =
        mode === "register"
          ? await navigator.credentials.create({ publicKey })
          : await navigator.credentials.get({ publicKey })

      if (!credential) throw new Error("empty credential")

      const payload =
        mode === "register" ? registrationPayload(credential) : assertionPayload(credential)

      const response = await fetch(endpoint, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "content-type": "application/json",
          "x-csrf-token": csrf,
        },
        body: JSON.stringify(payload),
      })

      let body = {}
      try {
        body = await response.json()
      } catch (_error) {
        body = {}
      }

      if (response.ok && body.redirect_to) {
        window.location.assign(body.redirect_to)
        return
      }

      setStatus(
        body.error || (mode === "register" ? text.genericRegister : text.generic),
        true,
      )
    } catch (error) {
      // DOMException carries name; a plain Error from an empty credential does
      // not, so fall through to the generic copy.
      setStatus(browserErrorCopy(error), true)
    } finally {
      if (button) button.disabled = false
    }
  }

  if (form) form.addEventListener("submit", submit)
})()
