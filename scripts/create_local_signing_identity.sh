#!/bin/zsh
# create_local_signing_identity.sh - create a self-signed code signing identity
# in the login keychain, for signing local builds with a stable identity.
#
# Run it yourself, once, in Terminal. Build scripts never run it.
#
#   ./scripts/create_local_signing_identity.sh              # "Whitney Local Code Signing"
#   ./scripts/create_local_signing_identity.sh "Other Name"
#
# Why
#   An ad hoc signature has no certificate, so macOS identifies the app by its
#   code hash (designated requirement: cdhash H"..."). Every rebuild is a new
#   hash, so privacy grants such as Accessibility stop matching. Signed with a
#   certificate, the designated requirement becomes
#       identifier "<bundle id>" and certificate leaf = H"<certificate hash>"
#   which stays the same for every build signed with the same certificate.
#
# What it does
#   1. Stops if an identity with this name already exists (idempotent).
#   2. Generates an RSA 2048 key and a self-signed certificate (code signing
#      usage only, not a CA, valid 10 years) in a private temporary directory.
#   3. Imports both into ~/Library/Keychains/login.keychain-db. The private key
#      is marked non-extractable and /usr/bin/codesign is allowed to use it.
#   4. Deletes the temporary files and prints the identity name to export.
#
# What it does not do
#   - No sudo, no System keychain, no change to trust settings, Gatekeeper or
#     any other security setting. The certificate is not trusted for anything;
#     codesign only needs the key pair. Apps signed with it are not notarized
#     and are meant for this Mac only.
#   - It does not sign or rebuild anything.
#
# Afterwards
#   export CODESIGN_IDENTITY="Whitney Local Code Signing"    # e.g. in ~/.zshenv
#   ./scripts/build_app.sh
#   The first codesign run asks for the login keychain password; choose
#   "Always Allow". The first build signed this way is still a different
#   identity from the old ad hoc build, so grant Accessibility once more in
#   System Settings > Privacy & Security > Accessibility (remove the old entry
#   and add the app again). Later builds keep the grant.
#
# Undo
#   security delete-identity -c "Whitney Local Code Signing" ~/Library/Keychains/login.keychain-db
#   unset CODESIGN_IDENTITY        # and remove the export line
#   Builds then sign ad hoc again. Recreating the identity yields a new
#   certificate hash, so the grant has to be given once more.

set -euo pipefail

IDENTITY_NAME="${1:-Whitney Local Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
VALID_DAYS=3650

if [[ $EUID -eq 0 ]]; then
    print -u2 "Run this as your own user, without sudo."
    exit 1
fi

if [[ ! "$IDENTITY_NAME" =~ '^[A-Za-z0-9][A-Za-z0-9 ._-]*$' ]]; then
    print -u2 "Identity name may contain only letters, digits, spaces, dots, underscores and hyphens."
    exit 1
fi

if [[ ! -f "$KEYCHAIN" ]]; then
    print -u2 "Login keychain not found: $KEYCHAIN"
    exit 1
fi

print_next_steps() {
    print ""
    print "Signing identity: $IDENTITY_NAME"
    print "Use it for builds with:"
    print "  export CODESIGN_IDENTITY=\"$IDENTITY_NAME\""
}

# Lists identities (certificate plus private key) usable for code signing,
# including self-signed ones that are not trusted.
if /usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep -Fq "\"$IDENTITY_NAME\""; then
    print "An identity named \"$IDENTITY_NAME\" already exists in the login keychain; nothing created."
    print_next_steps
    exit 0
fi

if /usr/bin/security find-certificate -a -c "$IDENTITY_NAME" "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"labl\"<blob>=\"$IDENTITY_NAME\""; then
    print -u2 "A certificate named \"$IDENTITY_NAME\" exists without a usable private key."
    print -u2 "Remove it in Keychain Access or choose another name, then run this again."
    exit 1
fi

umask 077
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/local-signing-identity.XXXXXX")"
trap 'rm -rf -- "$WORK_DIR"' EXIT

cat > "$WORK_DIR/openssl.cnf" <<CONFIG
[ req ]
distinguished_name = subject
x509_extensions = code_signing
prompt = no

[ subject ]
CN = $IDENTITY_NAME

[ code_signing ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CONFIG

# The system LibreSSL writes a PKCS#12 format that `security import` reads.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$VALID_DAYS" \
    -config "$WORK_DIR/openssl.cnf" \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/certificate.pem"

# Throwaway password that only protects the temporary bundle during import.
/usr/bin/openssl rand -hex 24 > "$WORK_DIR/transfer-password"

/usr/bin/openssl pkcs12 -export \
    -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/certificate.pem" \
    -name "$IDENTITY_NAME" \
    -out "$WORK_DIR/identity.p12" -passout "file:$WORK_DIR/transfer-password"

/usr/bin/security import "$WORK_DIR/identity.p12" \
    -k "$KEYCHAIN" -f pkcs12 -x \
    -P "$(cat "$WORK_DIR/transfer-password")" \
    -T /usr/bin/codesign

if ! /usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep -Fq "\"$IDENTITY_NAME\""; then
    print -u2 "The import finished but the identity is not listed for code signing."
    exit 1
fi

print "Created self-signed code signing identity \"$IDENTITY_NAME\" in the login keychain."
print_next_steps
print ""
print "The first build asks for the login keychain password (choose Always Allow),"
print "and Accessibility has to be granted to the newly signed app once."
