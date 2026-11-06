/// Controls the configured authorization interceptor. URLSession cookie storage is configured separately.
public enum AuthorizationRequirement: Sendable {
    case none
    case ifAvailable
    case required
}
