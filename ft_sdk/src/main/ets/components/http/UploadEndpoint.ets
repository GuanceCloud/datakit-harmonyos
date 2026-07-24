/**
 * Shared intake endpoint validation for upload scheduling code.
 * Arguments are supplied as a snapshot so this internal utility has no
 * dependency on the public configuration type.
 */
export function isUploadEndpointAvailable(
  datakitUrl: string,
  datawayUrl: string,
  clientToken: string
): boolean {
  const normalizedDatakitUrl = datakitUrl.trim();
  if (normalizedDatakitUrl.length > 0) {
    return isValidHttpUrl(normalizedDatakitUrl);
  }
  return isValidHttpUrl(datawayUrl.trim()) && clientToken.trim().length > 0;
}

/**
 * Accept complete HTTP(S) URLs with a host, including localhost, IPv4 and IPv6.
 * This deliberately rejects relative paths, non-HTTP schemes and malformed ports
 * before the scheduler creates an upload task.
 */
export function isValidHttpUrl(value: string): boolean {
  return /^https?:\/\/(?:\[[0-9a-f:.]+\]|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)(?:\.(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?))*)(?::\d+)?(?:[/?#]|$)/i.test(value);
}
