# Windows Defender reports iDeck.ipa as Wacatac

## What this report does and does not prove

Windows Security can classify an iOS IPA download as
`Trojan:Script/Wacatac.B!ml`. Microsoft describes that detection name as a
broad heuristic; neither the name nor this repository's source establishes
whether a specific detected file is malicious or a false positive.

The IPA is an iOS app archive, **not a Windows installer**. An IPA is a ZIP
container, so Defender may inspect JavaScript and Windows PE binaries
inside it. iDeck intentionally bundles the StikDebug debugger script used
to initialize Madeira JIT. That script interacts with debugger memory and
has a legacy dynamic JavaScript extension mechanism. These are reasons to
audit the archive, **not evidence that Defender has flagged that script**.

**Never disable Windows Defender or add broad exclusions to install iDeck.**
Do not restore or execute a quarantined file without investigating it.

## Find what Defender actually detected

1. Open **Windows Security → Virus & threat protection → Protection history**.
2. Open the Wacatac detection and expand **Affected items**. Note the exact
   detected path, original download URL, threat name and definition version.
   Defender might identify the IPA itself or an inner file in the archive.
3. Keep the file quarantined pending verification. If the file was downloaded
   from a third-party mirror, replace the source with the official
   `FacensPedro/iDeck` GitHub Release; do not assume a mirror is trustworthy.
4. Compare the file's SHA-256 with `iDeck.ipa.sha256` from the **same GitHub
   release**. For an unquarantined file, PowerShell can calculate a hash with
   `Get-FileHash -Algorithm SHA256 -Path .\iDeck.ipa`. A matching hash
   confirms the downloaded bytes match the published release artifact,
   **not that the artifact is malware-free**.
5. If the detection persists after updated definitions, submit the **exact
   detected file** to Microsoft's official
   [file submission portal](https://www.microsoft.com/wdsi/filesubmission)
   as a developer or home customer. Select **incorrectly detected as
   malicious** only if you have independently established it is clean.
   Include the detection path, SHA-256, GitHub release URL, build commit,
   Defender definition version, and the detected script or PE path when known.
6. Follow the verdict from Microsoft. Do not assert a false positive before
   the affected file is identified and reviewed.

Microsoft documentation:
- https://www.microsoft.com/en-us/wdsi/threats/malware-encyclopedia-description?name=Trojan%3AScript%2FWacatac.B%21ml&threatid=2147735503
- https://www.microsoft.com/wdsi/filesubmission

## Distribution controls in this repository

`scripts/audit_ipa_distribution.py` is run on the **built IPA** before the
artifact is offered for distribution. It checks:

- all archive member names for path escapes and duplicates;
- presence of the application's Info.plist and iDeck's primary JIT script;
- SHA-256 integrity of bundled JIT scripts against the checked-in sources;
- inventory of script files inside the app, including scripts outside
  the reviewed JIT sources;
- the complete IPA SHA-256, without modifying or repacking it.

The build uploads a separate `iDeck-security-receipts` artifact with
`iDeck.ipa.sha256` and `iDeck-distribution-audit.json`. Published GitHub
Releases also include those files. Release publication verifies that the
downloaded IPA exactly matches its recorded hash.

These steps check **provenance and integrity only**: they are not antivirus
scanning, notarization, Windows code signing, a Windows Defender
allowlisting service, or proof that every native payload is harmless.
The scripts cannot determine why a user-specific Defender detection occurred
without the name/hash of the specific flagged file.

## Guidelines for developers

- Build with pinned source and validated native runtime dependencies.
- Do not silence the Defender alert by changing script encodings, packing,
  renaming extensions, obfuscating code or adding scanner exclusions.
- If the alert identifies a particular iDeck source artifact, investigate
  that file and its upstream provenance. Remove unintended functionality;
  preserve necessary StikDebug/JIT behavior rather than disguising it.
- Do not claim the IPA has passed Microsoft Defender until Microsoft
  confirms the specific submitted build and signatures.
