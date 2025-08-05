{{- /*
Generate a SHA256 checksum of the .Values.config object.
Used to trigger pod restarts when config changes.
*/ -}}
{{- define "cloudflared.configChecksum" -}}
{{- toJson .Values.config | sha256sum -}}
{{- end -}}
