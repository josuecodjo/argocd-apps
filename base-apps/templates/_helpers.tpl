{{/*
Shared syncPolicy for every generated Application, so the Helm-chart apps in
charts.yaml and the plain git-path apps in apps.yaml cannot drift apart.

Usage:  {{- include "base-apps.syncPolicy" (dict "app" $app) | nindent 2 }}

Recognised keys on the app:
  autosync_enabled  set false to omit syncPolicy entirely
  serverSideApply   adds ServerSideApply=true (needed for large CRDs)
*/}}
{{- define "base-apps.syncPolicy" -}}
{{- $app := .app -}}
{{- if ne $app.autosync_enabled false }}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
    allowEmpty: false
  syncOptions:
    - Validate=false
    - CreateNamespace=true
    - PrunePropagationPolicy=foreground
    - PruneLast=true
    - RespectIgnoreDifferences=true
    - ApplyOutOfSyncOnly=true
    {{- if $app.serverSideApply }}
    - ServerSideApply=true
    {{- end }}
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
{{- end }}
{{- end -}}
