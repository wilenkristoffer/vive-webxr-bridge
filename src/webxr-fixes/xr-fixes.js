// Runs in every page and frame of the bridge's Edge, before the page's own scripts.
//
// With VIVE's runtime, a WebXR session that asks for hand tracking never starts: requestSession
// stays pending forever and the page's Enter VR button does nothing (VIVE's hand tracking layer
// has to stay off, because it crashes Edge). So hand tracking is taken out of the request, even
// when the page lists it as required: the session then starts with controllers instead of hands,
// which is more useful than a button that does nothing. Pages can still see that hands are
// missing, since session.enabledFeatures won't include 'hand-tracking'.
(() => {
    const unavailable = ['hand-tracking'];
    const proto = globalThis.XRSystem && XRSystem.prototype;
    if (!proto || !proto.requestSession) return;
    const requestSession = proto.requestSession;
    const without = list => [...(list || [])].filter(f => !unavailable.includes(f));

    proto.requestSession = function (mode, options) {
        if (options) {
            const required = without(options.requiredFeatures);
            const optional = without(options.optionalFeatures);
            if (required.length !== [...(options.requiredFeatures || [])].length ||
                optional.length !== [...(options.optionalFeatures || [])].length) {
                console.info('vive-webxr-bridge: hand tracking removed from this VR request, since it never starts with VIVE\'s runtime. Controllers work.');
                options = { ...options, requiredFeatures: required, optionalFeatures: optional };
            }
        }
        return requestSession.call(this, mode, options);
    };
})();
