{{- define "helm-toolkit.snippets.tls_owner_fix_init_container" -}}
{{- $uid := default 0 (index . "uid") -}}
{{- $gid := default 0 (index . "gid") -}}
{{- $tlsSecret := default "" (index . "tlsSecret") -}}
{{- $targetVolume := default "" (index . "targetVolume") -}}
{{- if and (ne $tlsSecret "") (ne $targetVolume "") }}
- name: {{ $tlsSecret }}-tls-owner-fix
  image: "alpine:edge"
  securityContext:
    runAsUser: 0
  volumeMounts:
  - name: {{ $targetVolume }}
    mountPath: /etc/tls/dest
{{- dict "enabled" true "name" $tlsSecret "path" "/etc/tls/src" | include "helm-toolkit.snippets.tls_volume_mount" | indent 2 }}
  command:
  - "/bin/sh"
  - "-xc"
  - |
    cp /etc/tls/src/* /etc/tls/dest/
    find /etc/tls/dest -type f -iname "*.crt" -print0 | xargs -0 -I'{}' -- /bin/sh -c 'chmod 0444 {}; chown {{ $uid }}:{{ $gid }} {}'
    find /etc/tls/dest -type f -iname "*.key" -print0 | xargs -0 -I'{}' -- /bin/sh -c 'chmod 0400 {}; chown {{ $uid }}:{{ $gid }} {}'
    exit 0
{{- end -}}
{{- end -}}
