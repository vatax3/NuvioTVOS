import Foundation
import JavaScriptCore
import CryptoKit
import os

/// Result of one scraper run — mirrors `LocalScraperResult` in the Android app, including the
/// field names, because scraper JS returns objects with exactly these keys.
struct LocalScraperResult: Decodable, Hashable, Sendable {
    var title: String?
    var name: String?
    var url: String
    var quality: String?
    var size: String?
    var language: String?
    var provider: String?
    var type: String?
    var seeders: Int?
    var peers: Int?
    var infoHash: String?
    var headers: [String: String]?

    var displayTitle: String { name?.nilIfBlank ?? title?.nilIfBlank ?? url }
}

/// Runs Nuvio JS scrapers.
///
/// The Android build embeds QuickJS; on Apple platforms JavaScriptCore is already in the SDK and
/// gives the same thing. The globals a scraper sees are matched to the Android runtime:
/// `module.exports`, `console`, `fetch`, `cheerio.load`, `atob`/`btoa`, `AbortController`,
/// `CryptoJS` hash/HMAC helpers, `SCRAPER_ID`, `SCRAPER_SETTINGS` and `TMDB_API_KEY`, and the entry point is
/// `getStreams(tmdbId, mediaType, season, episode)`.
///
/// One deliberate difference: `fetch` is synchronous underneath (the JS side still awaits a
/// resolved promise, exactly as on Android), so each execution owns a thread it is allowed to
/// block. That is why this is an actor with its own queue rather than main-thread work.
actor PluginRuntime {
    static let shared = PluginRuntime()

    private let log = Logger(subsystem: "com.nuvio.tvos", category: "PluginRuntime")
    private let timeout: TimeInterval = 60
    /// Guards against a runaway scraper pulling down a huge body.
    private let maxResponseBytes = 1024 * 1024

    func execute(
        code: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
        scraperId: String,
        settings: [String: Any] = [:],
        tmdbApiKey: String = ""
    ) async -> [LocalScraperResult] {
        let work = Task.detached(priority: .userInitiated) { [self] in
            run(
                code: code, tmdbId: tmdbId, mediaType: mediaType,
                season: season, episode: episode,
                scraperId: scraperId, settings: settings, tmdbApiKey: tmdbApiKey
            )
        }

        // A scraper that never returns must not hold the streams screen open forever.
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            work.cancel()
        }
        defer { timeoutTask.cancel() }

        return await work.value
    }

    // MARK: Execution

    private nonisolated func run(
        code: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
        scraperId: String,
        settings: [String: Any],
        tmdbApiKey: String
    ) -> [LocalScraperResult] {
        guard let context = JSContext() else { return [] }
        let bridge = PluginBridge(maxResponseBytes: maxResponseBytes, log: log, scraperId: scraperId)

        context.exceptionHandler = { [log] _, exception in
            log.error("\(scraperId, privacy: .public): \(exception?.toString() ?? "unknown", privacy: .public)")
        }

        bridge.install(in: context)

        let settingsJson = (try? JSONSerialization.data(withJSONObject: settings))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        context.setObject(scraperId, forKeyedSubscript: "SCRAPER_ID" as NSString)
        context.evaluateScript("globalThis.SCRAPER_SETTINGS = \(settingsJson);")
        context.setObject(tmdbApiKey, forKeyedSubscript: "TMDB_API_KEY" as NSString)

        context.evaluateScript(Self.polyfill)
        context.evaluateScript(code)

        let args: [String: Any] = [
            "tmdbId": tmdbId,
            "mediaType": mediaType,
            "season": season as Any? ?? NSNull(),
            "episode": episode as Any? ?? NSNull()
        ]
        let argsJson = (try? JSONSerialization.data(withJSONObject: args))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        context.evaluateScript("globalThis.__call_args = \(argsJson);")
        context.evaluateScript(Self.callShim)

        // `getStreams` is async, so the promise settles on the microtask queue. JSC drains it
        // when control returns to the VM; poll the captured result while pumping the queue.
        let deadline = Date().addingTimeInterval(timeout)
        while bridge.capturedResult == nil, Date() < deadline {
            if Task.isCancelled { return [] }
            context.evaluateScript("void 0;")
            Thread.sleep(forTimeInterval: 0.01)
        }

        guard let json = bridge.capturedResult else {
            log.error("\(scraperId, privacy: .public) produced no result before the timeout")
            return []
        }
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            // One malformed entry must not discard the whole batch.
            let entries = try JSONDecoder().decode([Failable<LocalScraperResult>].self, from: data)
            return entries.compactMap(\.value).filter { !$0.url.isEmpty }
        } catch {
            log.error("\(scraperId, privacy: .public) returned undecodable JSON: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: Injected JS

    /// Same entry-point contract as the Android runtime: `module.exports.getStreams`, falling
    /// back to a bare global for scrapers that never touch `module`.
    private static let callShim = """
    (async function() {
        try {
            var getStreams = (typeof module !== 'undefined' && module.exports && module.exports.getStreams)
                || globalThis.getStreams;
            if (!getStreams) {
                console.error('getStreams function not found on module.exports or globalThis');
                __capture_result('[]');
                return;
            }
            var args = globalThis.__call_args;
            var result = await getStreams(args.tmdbId, args.mediaType, args.season, args.episode);
            __capture_result(JSON.stringify(result || []));
        } catch (e) {
            console.error('getStreams error:', (e && e.message) || e, (e && e.stack) || '');
            __capture_result('[]');
        }
    })();
    """

    private static let polyfill = """
    (function() {
        if (typeof globalThis.global === 'undefined') globalThis.global = globalThis;
        if (typeof globalThis.window === 'undefined') globalThis.window = globalThis;
        if (typeof globalThis.self === 'undefined') globalThis.self = globalThis;
        if (typeof globalThis.module === 'undefined') globalThis.module = { exports: {} };
        if (typeof globalThis.exports === 'undefined') globalThis.exports = globalThis.module.exports;
        // Android bundles crypto-js. The native bridge supplies the commonly-used subset:
        // WordArray encoders, MD5/SHA hashes and HMACs, PBKDF2, and AES CBC/ECB/GCM. Keeping the
        // primitives native avoids shipping a large JavaScript cipher implementation on tvOS;
        // uncommon legacy algorithms below fail explicitly instead of returning corrupt bytes.
        if (typeof globalThis.CryptoJS === 'undefined') {
            function NuvioWordArray(base64) {
                this.__nuvio_base64 = base64 || '';
                this.sigBytes = Math.floor((this.__nuvio_base64.length * 3) / 4);
            }
            NuvioWordArray.prototype.toString = function(encoder) {
                return (encoder || NuvioCrypto.enc.Hex).stringify(this);
            };
            NuvioWordArray.prototype.concat = function(wordArray) {
                this.__nuvio_base64 = __crypto_concat(this.__nuvio_base64, NuvioCrypto.bytes(wordArray));
                this.sigBytes = Math.floor((this.__nuvio_base64.length * 3) / 4);
                return this;
            };
            NuvioWordArray.prototype.clamp = function() { return this; };

            function bytes(value) {
                if (value && typeof value.__nuvio_base64 === 'string') return value.__nuvio_base64;
                return __crypto_utf8_to_base64(String(value == null ? '' : value));
            }
            function wordArray(base64) { return new NuvioWordArray(base64); }
            function digest(name, message, key) {
                return wordArray(__crypto_digest(name, bytes(message), key == null ? '' : bytes(key)));
            }
            function hasher(name) {
                return {
                    __nuvio_algorithm: name,
                    create: function() {
                        var body = wordArray('');
                        return {
                            update: function(value) { body.concat(value); return this; },
                            finalize: function(value) {
                                if (value != null) body.concat(value);
                                return digest(name, body);
                            }
                        };
                    }
                };
            }
            var NuvioCrypto = {
                bytes: bytes,
                enc: {
                    Hex: {
                        stringify: function(value) { return __crypto_base64_to_hex(bytes(value)); },
                        parse: function(value) { return wordArray(__crypto_hex_to_base64(String(value))); }
                    },
                    Base64: {
                        stringify: function(value) { return bytes(value); },
                        parse: function(value) { return wordArray(String(value)); }
                    },
                    Utf8: {
                        stringify: function(value) { return __crypto_base64_to_utf8(bytes(value)); },
                        parse: function(value) { return wordArray(__crypto_utf8_to_base64(String(value))); }
                    }
                },
                lib: {
                    WordArray: {
                        create: function(words, sigBytes) {
                            if (words && typeof words.__nuvio_base64 === 'string') return words;
                            if (Array.isArray(words)) return wordArray(__crypto_words_to_base64(JSON.stringify(words), sigBytes == null ? words.length * 4 : sigBytes));
                            return wordArray(bytes(words));
                        },
                        random: function(count) { return wordArray(__crypto_random(Math.max(0, Number(count) || 0))); }
                    }
                }
            };
            ['MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512'].forEach(function(name) {
                NuvioCrypto[name] = function(message) { return digest(name, message); };
                NuvioCrypto['Hmac' + name] = function(message, key) { return digest('HMAC' + name, message, key); };
                NuvioCrypto.algo = NuvioCrypto.algo || {};
                NuvioCrypto.algo[name] = hasher(name);
            });
            function algorithmName(hasher) {
                return hasher && hasher.__nuvio_algorithm ? hasher.__nuvio_algorithm : (hasher || 'SHA1');
            }
            function evpKdf(password, salt, keySize, ivSize) {
                var required = keySize + ivSize, output = wordArray(''), block = wordArray('');
                while (Math.floor((output.__nuvio_base64.length * 3) / 4) < required) {
                    block = digest('MD5', block.concat(password).concat(salt));
                    output.concat(block);
                }
                var raw = atob(output.__nuvio_base64).slice(0, required);
                return {
                    key: wordArray(btoa(raw.slice(0, keySize))),
                    iv: wordArray(btoa(raw.slice(keySize, keySize + ivSize)))
                };
            }
            function cipherParams(ciphertext, key, iv, salt, mode) {
                return {
                    ciphertext: ciphertext, key: key, iv: iv, salt: salt, mode: mode,
                    toString: function(formatter) { return (formatter || NuvioCrypto.format.OpenSSL).stringify(this); }
                };
            }
            NuvioCrypto.lib.CipherParams = { create: function(params) {
                params = params || {};
                params.toString = params.toString || function(formatter) {
                    return (formatter || NuvioCrypto.format.OpenSSL).stringify(this);
                };
                return params;
            } };
            NuvioCrypto.mode = { CBC: 'AES-CBC', GCM: 'AES-GCM', ECB: 'AES-ECB' };
            NuvioCrypto.pad = { Pkcs7: 'Pkcs7', NoPadding: 'NoPadding' };
            NuvioCrypto.format = { OpenSSL: {
                stringify: function(params) {
                    var cipher = atob(bytes(params.ciphertext));
                    var raw = params.salt ? 'Salted__' + atob(bytes(params.salt)) + cipher : cipher;
                    return btoa(raw);
                },
                parse: function(value) {
                    var raw = atob(String(value || ''));
                    if (raw.slice(0, 8) === 'Salted__' && raw.length >= 16) {
                        return cipherParams(wordArray(btoa(raw.slice(16))), null, null, wordArray(btoa(raw.slice(8, 16))));
                    }
                    return cipherParams(wordArray(btoa(raw)));
                }
            } };
            NuvioCrypto.PBKDF2 = function(password, salt, options) {
                options = options || {};
                var keySize = Math.max(1, Number(options.keySize) || 8);
                var iterations = Math.max(1, Number(options.iterations) || 1000);
                return wordArray(__crypto_pbkdf2(bytes(password), bytes(salt), iterations, keySize * 4, algorithmName(options.hasher)));
            };
            NuvioCrypto.AES = {
                encrypt: function(message, key, options) {
                    options = options || {};
                    var salt, keyBytes, ivBytes;
                    if (typeof key === 'string') {
                        salt = options.salt || NuvioCrypto.lib.WordArray.random(8);
                        var derived = evpKdf(wordArray(__crypto_utf8_to_base64(key)), salt, 32, 16);
                        keyBytes = derived.key;
                        ivBytes = options.iv || derived.iv;
                    } else {
                        keyBytes = key;
                        ivBytes = options.iv || wordArray('');
                    }
                    var mode = options.mode || NuvioCrypto.mode.CBC;
                    if (options.padding === NuvioCrypto.pad.NoPadding) mode += '-NoPadding';
                    return cipherParams(
                        wordArray(__crypto_aes(true, mode, bytes(keyBytes), bytes(ivBytes), bytes(message))),
                        keyBytes, ivBytes, salt, mode
                    );
                },
                decrypt: function(cipher, key, options) {
                    options = options || {};
                    var params = typeof cipher === 'string' ? NuvioCrypto.format.OpenSSL.parse(cipher) : cipher;
                    var salt, keyBytes, ivBytes;
                    if (typeof key === 'string') {
                        salt = options.salt || params.salt;
                        if (!salt) throw new Error('AES passphrase ciphertext has no OpenSSL salt');
                        var derived = evpKdf(wordArray(__crypto_utf8_to_base64(key)), salt, 32, 16);
                        keyBytes = derived.key;
                        ivBytes = options.iv || derived.iv;
                    } else {
                        keyBytes = key;
                        ivBytes = options.iv || wordArray('');
                    }
                    var mode = options.mode || NuvioCrypto.mode.CBC;
                    if (options.padding === NuvioCrypto.pad.NoPadding) mode += '-NoPadding';
                    return wordArray(__crypto_aes(false, mode, bytes(keyBytes), bytes(ivBytes), bytes(params.ciphertext || params)));
                }
            };
            function cipherUnavailable() {
                throw new Error('This legacy cipher is not available in the tvOS plugin runtime');
            }
            NuvioCrypto.DES = { encrypt: cipherUnavailable, decrypt: cipherUnavailable };
            NuvioCrypto.TripleDES = { encrypt: cipherUnavailable, decrypt: cipherUnavailable };
            globalThis.CryptoJS = NuvioCrypto;
        }
        if (typeof globalThis.require === 'undefined') {
            globalThis.require = function(name) {
                if (name === 'cheerio') return globalThis.cheerio;
                if (name === 'crypto-js' && globalThis.CryptoJS) return globalThis.CryptoJS;
                throw new Error('require("' + name + '") is not available in this runtime');
            };
        }

        // AbortController is referenced by scrapers passing a signal to fetch. The native fetch
        // is synchronous, so a signal can never fire mid-request — the shim exists so the code
        // runs, and aborting is a no-op rather than a crash.
        if (typeof globalThis.AbortController === 'undefined') {
            globalThis.AbortSignal = function() { this.aborted = false; };
            globalThis.AbortController = function() {
                this.signal = new globalThis.AbortSignal();
                this.abort = function() { this.signal.aborted = true; };
            };
        }

        globalThis.fetch = function(url, options) {
            var raw = __native_fetch(String(url), JSON.stringify(options || {}));
            var parsed = JSON.parse(raw);
            var headers = parsed.headers || {};
            var response = {
                ok: parsed.status >= 200 && parsed.status < 300,
                status: parsed.status,
                statusText: parsed.statusText || '',
                url: parsed.url || String(url),
                redirected: !!parsed.redirected,
                headers: {
                    get: function(name) {
                        var key = String(name).toLowerCase();
                        return Object.prototype.hasOwnProperty.call(headers, key) ? headers[key] : null;
                    },
                    has: function(name) {
                        return Object.prototype.hasOwnProperty.call(headers, String(name).toLowerCase());
                    },
                    forEach: function(callback) {
                        Object.keys(headers).forEach(function(key) { callback(headers[key], key); });
                    },
                    entries: function() {
                        return Object.keys(headers).map(function(key) { return [key, headers[key]]; });
                    }
                },
                text: function() { return Promise.resolve(parsed.body || ''); },
                json: function() {
                    try { return Promise.resolve(JSON.parse(parsed.body || 'null')); }
                    catch (e) { return Promise.reject(e); }
                }
            };
            if (parsed.error) return Promise.reject(new Error(parsed.error));
            return Promise.resolve(response);
        };

        // Cheerio subset over the native HTML parser: the call surface the Android shim exposes.
        function wrap(ids) {
            var api = {
                length: ids.length,
                _ids: ids,
                get: function(i) { return ids[i]; },
                eq: function(i) { return wrap(i < ids.length && i >= 0 ? [ids[i]] : []); },
                first: function() { return api.eq(0); },
                last: function() { return api.eq(ids.length - 1); },
                find: function(selector) { return wrap(JSON.parse(__cheerio_find(JSON.stringify(ids), selector))); },
                text: function() { return __cheerio_text(JSON.stringify(ids)); },
                html: function() { return __cheerio_inner_html(JSON.stringify(ids)); },
                attr: function(name) {
                    var value = __cheerio_attr(JSON.stringify(ids), String(name));
                    return value === null ? undefined : value;
                },
                next: function() { return wrap(JSON.parse(__cheerio_next(JSON.stringify(ids)))); },
                prev: function() { return wrap(JSON.parse(__cheerio_prev(JSON.stringify(ids)))); },
                each: function(callback) {
                    for (var i = 0; i < ids.length; i++) { callback(i, wrap([ids[i]])); }
                    return api;
                },
                map: function(callback) {
                    var out = [];
                    for (var i = 0; i < ids.length; i++) { out.push(callback(i, wrap([ids[i]]))); }
                    return { get: function() { return out; }, toArray: function() { return out; } };
                },
                toArray: function() {
                    var out = [];
                    for (var i = 0; i < ids.length; i++) { out.push(wrap([ids[i]])); }
                    return out;
                }
            };
            return api;
        }

        globalThis.cheerio = {
            load: function(html) {
                var docId = __cheerio_load(String(html));
                var $ = function(selector, scope) {
                    if (scope && scope._ids) {
                        return wrap(JSON.parse(__cheerio_find(JSON.stringify(scope._ids), String(selector))));
                    }
                    return wrap(JSON.parse(__cheerio_select(docId, String(selector))));
                };
                $.root = function() { return wrap([docId]); };
                $.html = function() { return __cheerio_inner_html(JSON.stringify([docId])); };
                return $;
            }
        };
    })();
    """
}

// MARK: - Native bridge

/// Holds the native side of the runtime: fetch, the cheerio handles and the result capture.
/// One instance per execution, so handles cannot leak between scrapers.
private final class PluginBridge {
    private let maxResponseBytes: Int
    private let log: Logger
    private let scraperId: String

    /// Parsed documents and elements, addressed by opaque string handles — same shape as the
    /// Android bindings, which is what lets the JS shim be a near-copy.
    private var nodes: [String: HTMLNode] = [:]
    private var nextHandle = 0
    private let lock = NSLock()

    private(set) var capturedResult: String?

    init(maxResponseBytes: Int, log: Logger, scraperId: String) {
        self.maxResponseBytes = maxResponseBytes
        self.log = log
        self.scraperId = scraperId
    }

    func install(in context: JSContext) {
        installConsole(in: context)
        installFetch(in: context)
        installCheerio(in: context)
        installBase64(in: context)
        installCrypto(in: context)

        let capture: @convention(block) (String) -> Void = { [weak self] json in
            self?.capturedResult = json
        }
        context.setObject(capture, forKeyedSubscript: "__capture_result" as NSString)
    }

    // MARK: Console

    private func installConsole(in context: JSContext) {
        let logger = log
        let identifier = scraperId
        let sink: @convention(block) (String) -> Void = { message in
            logger.debug("\(identifier, privacy: .public): \(message, privacy: .public)")
        }
        let console = JSValue(newObjectIn: context)
        for level in ["log", "info", "debug", "warn", "error"] {
            console?.setObject(sink, forKeyedSubscript: level as NSString)
        }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: Fetch

    private func installFetch(in context: JSContext) {
        let limit = maxResponseBytes
        let fetch: @convention(block) (String, String) -> String = { urlString, optionsJson in
            PluginBridge.performFetch(urlString: urlString, optionsJson: optionsJson, limit: limit)
        }
        context.setObject(fetch, forKeyedSubscript: "__native_fetch" as NSString)
    }

    /// Blocking on purpose: the JS `fetch` shim resolves an already-settled promise, and this
    /// whole execution runs on its own detached task.
    private static func performFetch(urlString: String, optionsJson: String, limit: Int) -> String {
        func encode(_ payload: [String: Any]) -> String {
            (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"status\":0,\"error\":\"encode failed\"}"
        }

        guard let url = URL(string: urlString) else {
            return encode(["status": 0, "error": "invalid url", "body": ""])
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let data = optionsJson.data(using: .utf8),
           let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let method = options["method"] as? String { request.httpMethod = method.uppercased() }
            if let headers = options["headers"] as? [String: Any] {
                for (key, value) in headers { request.setValue(String(describing: value), forHTTPHeaderField: key) }
            }
            if let body = options["body"] as? String { request.httpBody = body.data(using: .utf8) }
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var payload: [String: Any] = ["status": 0, "error": "no response", "body": ""]

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                payload = ["status": 0, "error": error.localizedDescription, "body": ""]
                return
            }
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (key, value) in http?.allHeaderFields ?? [:] {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            let truncated = (data ?? Data()).prefix(limit)
            let body = String(data: truncated, encoding: .utf8)
                ?? String(data: truncated, encoding: .isoLatin1)
                ?? ""
            payload = [
                "status": http?.statusCode ?? 0,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 0),
                "url": response?.url?.absoluteString ?? urlString,
                "headers": headers,
                "body": body
            ]
        }
        task.resume()
        // Slightly beyond the request timeout so a hung socket still unblocks the thread.
        _ = semaphore.wait(timeout: .now() + 35)
        return encode(payload)
    }

    // MARK: Cheerio handles

    private func handle(for node: HTMLNode) -> String {
        lock.lock()
        defer { lock.unlock() }
        nextHandle += 1
        let id = "n\(nextHandle)"
        nodes[id] = node
        return id
    }

    private func node(for handle: String) -> HTMLNode? {
        lock.lock()
        defer { lock.unlock() }
        return nodes[handle]
    }

    private func nodes(forHandlesJson json: String) -> [HTMLNode] {
        guard let data = json.data(using: .utf8),
              let handles = try? JSONSerialization.jsonObject(with: data) as? [String] else { return [] }
        return handles.compactMap { node(for: $0) }
    }

    private func handlesJson(_ nodes: [HTMLNode]) -> String {
        let handles = nodes.map { handle(for: $0) }
        return (try? JSONSerialization.data(withJSONObject: handles))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    private func installCheerio(in context: JSContext) {
        let load: @convention(block) (String) -> String = { [weak self] html in
            guard let self else { return "" }
            return self.handle(for: HTMLParser.parse(html))
        }
        context.setObject(load, forKeyedSubscript: "__cheerio_load" as NSString)

        let select: @convention(block) (String, String) -> String = { [weak self] docHandle, selector in
            guard let self, let document = self.node(for: docHandle) else { return "[]" }
            return self.handlesJson(document.select(selector))
        }
        context.setObject(select, forKeyedSubscript: "__cheerio_select" as NSString)

        let find: @convention(block) (String, String) -> String = { [weak self] handlesJson, selector in
            guard let self else { return "[]" }
            let matches = self.nodes(forHandlesJson: handlesJson).flatMap { $0.select(selector) }
            return self.handlesJson(matches)
        }
        context.setObject(find, forKeyedSubscript: "__cheerio_find" as NSString)

        let text: @convention(block) (String) -> String = { [weak self] handlesJson in
            guard let self else { return "" }
            return self.nodes(forHandlesJson: handlesJson).map(\.text).joined(separator: " ")
        }
        context.setObject(text, forKeyedSubscript: "__cheerio_text" as NSString)

        let innerHTML: @convention(block) (String) -> String = { [weak self] handlesJson in
            guard let self else { return "" }
            return self.nodes(forHandlesJson: handlesJson).map(\.innerHTML).joined()
        }
        context.setObject(innerHTML, forKeyedSubscript: "__cheerio_inner_html" as NSString)

        let outerHTML: @convention(block) (String) -> String = { [weak self] handlesJson in
            guard let self else { return "" }
            return self.nodes(forHandlesJson: handlesJson).map(\.outerHTML).joined()
        }
        context.setObject(outerHTML, forKeyedSubscript: "__cheerio_html" as NSString)

        // Returns null rather than "" for a missing attribute, so `attr()` can yield undefined.
        let attribute: @convention(block) (String, String) -> String? = { [weak self] handlesJson, name in
            guard let self else { return nil }
            return self.nodes(forHandlesJson: handlesJson).first?.attributes[name.lowercased()]
        }
        context.setObject(attribute, forKeyedSubscript: "__cheerio_attr" as NSString)

        let next: @convention(block) (String) -> String = { [weak self] handlesJson in
            guard let self else { return "[]" }
            return self.handlesJson(self.nodes(forHandlesJson: handlesJson).compactMap(\.nextElement))
        }
        context.setObject(next, forKeyedSubscript: "__cheerio_next" as NSString)

        let previous: @convention(block) (String) -> String = { [weak self] handlesJson in
            guard let self else { return "[]" }
            return self.handlesJson(self.nodes(forHandlesJson: handlesJson).compactMap(\.previousElement))
        }
        context.setObject(previous, forKeyedSubscript: "__cheerio_prev" as NSString)
    }

    // MARK: Base64

    private func installBase64(in context: JSContext) {
        let decode: @convention(block) (String) -> String = { input in
            let padded = input.padding(
                toLength: ((input.count + 3) / 4) * 4, withPad: "=", startingAt: 0
            )
            guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else { return "" }
            // atob/btoa are binary-string APIs, not UTF-8 APIs. Keeping every byte as a
            // Latin-1 scalar is essential for OpenSSL-formatted AES values and plugin keys.
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
        context.setObject(decode, forKeyedSubscript: "atob" as NSString)

        let encode: @convention(block) (String) -> String = { input in
            let bytes = input.unicodeScalars.compactMap { UInt8(exactly: $0.value) }
            return Data(bytes).base64EncodedString()
        }
        context.setObject(encode, forKeyedSubscript: "btoa" as NSString)
    }

    // MARK: crypto-js compatibility

    private func installCrypto(in context: JSContext) {
        let digest: @convention(block) (String, String, String) -> String = { algorithm, messageBase64, keyBase64 in
            let message = Data(base64Encoded: messageBase64, options: .ignoreUnknownCharacters) ?? Data()
            let key = Data(base64Encoded: keyBase64, options: .ignoreUnknownCharacters) ?? Data()
            return Self.digest(algorithm: algorithm, message: message, key: key)?.base64EncodedString() ?? ""
        }
        context.setObject(digest, forKeyedSubscript: "__crypto_digest" as NSString)

        let hexToBase64: @convention(block) (String) -> String = { hex in
            Self.data(fromHex: hex)?.base64EncodedString() ?? ""
        }
        context.setObject(hexToBase64, forKeyedSubscript: "__crypto_hex_to_base64" as NSString)

        let base64ToHex: @convention(block) (String) -> String = { base64 in
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
            return data.map { String(format: "%02x", $0) }.joined()
        }
        context.setObject(base64ToHex, forKeyedSubscript: "__crypto_base64_to_hex" as NSString)

        let utf8ToBase64: @convention(block) (String) -> String = { $0.data(using: .utf8)?.base64EncodedString() ?? "" }
        context.setObject(utf8ToBase64, forKeyedSubscript: "__crypto_utf8_to_base64" as NSString)

        let base64ToUTF8: @convention(block) (String) -> String = { base64 in
            let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        }
        context.setObject(base64ToUTF8, forKeyedSubscript: "__crypto_base64_to_utf8" as NSString)

        let concatenate: @convention(block) (String, String) -> String = { lhs, rhs in
            let left = Data(base64Encoded: lhs, options: .ignoreUnknownCharacters) ?? Data()
            let right = Data(base64Encoded: rhs, options: .ignoreUnknownCharacters) ?? Data()
            return (left + right).base64EncodedString()
        }
        context.setObject(concatenate, forKeyedSubscript: "__crypto_concat" as NSString)

        let wordsToBase64: @convention(block) (String, Int) -> String = { wordsJSON, sigBytes in
            guard let json = wordsJSON.data(using: .utf8),
                  let words = try? JSONSerialization.jsonObject(with: json) as? [NSNumber] else { return "" }
            var data = Data()
            for word in words {
                var value = UInt32(truncating: word).bigEndian
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            return data.prefix(max(0, sigBytes)).base64EncodedString()
        }
        context.setObject(wordsToBase64, forKeyedSubscript: "__crypto_words_to_base64" as NSString)

        let random: @convention(block) (Int) -> String = { requestedCount in
            let count = min(max(0, requestedCount), 1_048_576)
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }).base64EncodedString()
        }
        context.setObject(random, forKeyedSubscript: "__crypto_random" as NSString)

        let pbkdf2: @convention(block) (String, String, Int, Int, String) -> String = {
            passwordBase64, saltBase64, iterations, keyLength, algorithm in
            let password = Data(base64Encoded: passwordBase64, options: .ignoreUnknownCharacters) ?? Data()
            let salt = Data(base64Encoded: saltBase64, options: .ignoreUnknownCharacters) ?? Data()
            return PluginCrypto.pbkdf2(
                password: password, salt: salt, iterations: iterations,
                keyLength: keyLength, algorithm: algorithm
            )?.base64EncodedString() ?? ""
        }
        context.setObject(pbkdf2, forKeyedSubscript: "__crypto_pbkdf2" as NSString)

        let aes: @convention(block) (Bool, String, String, String, String) -> String = {
            encrypting, mode, keyBase64, ivBase64, inputBase64 in
            let key = Data(base64Encoded: keyBase64, options: .ignoreUnknownCharacters) ?? Data()
            let iv = Data(base64Encoded: ivBase64, options: .ignoreUnknownCharacters) ?? Data()
            let input = Data(base64Encoded: inputBase64, options: .ignoreUnknownCharacters) ?? Data()
            return PluginCrypto.aes(
                encrypting: encrypting, mode: mode, key: key, iv: iv, input: input
            )?.base64EncodedString() ?? ""
        }
        context.setObject(aes, forKeyedSubscript: "__crypto_aes" as NSString)
    }

    private static func digest(algorithm: String, message: Data, key: Data) -> Data? {
        switch algorithm.uppercased() {
        case "MD5": return Data(Insecure.MD5.hash(data: message))
        case "SHA1": return Data(Insecure.SHA1.hash(data: message))
        case "SHA256": return Data(SHA256.hash(data: message))
        case "SHA384": return Data(SHA384.hash(data: message))
        case "SHA512": return Data(SHA512.hash(data: message))
        case "HMACMD5": return Data(HMAC<Insecure.MD5>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "HMACSHA1": return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "HMACSHA256": return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "HMACSHA384": return Data(HMAC<SHA384>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        case "HMACSHA512": return Data(HMAC<SHA512>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        default: return nil
        }
    }

    private static func data(fromHex value: String) -> Data? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
