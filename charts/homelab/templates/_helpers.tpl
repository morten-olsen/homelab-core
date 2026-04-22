{{/*
homelab.operatorValues
Constructs the helm values YAML block for the operators (core) sub-chart.
Maps feature flags to individual operator enabled/disabled states.
*/}}
{{- define "homelab.operatorValues" -}}
global:
  project: core
operators:
  argocd:
    enabled: {{ .Values.features.gitops }}
  authentik:
    enabled: {{ .Values.features.auth }}
  cert-manager:
    enabled: {{ .Values.features.certificates }}
  cloudnative-pg:
    enabled: {{ .Values.features.postgres }}
  dns-operator:
    enabled: {{ .Values.features.dns }}
  external-secrets:
    enabled: {{ .Values.features.secrets }}
  falco:
    enabled: {{ .Values.features.security }}
  istio-base:
    enabled: {{ .Values.features.serviceMesh }}
  istiod:
    enabled: {{ .Values.features.serviceMesh }}
  kyverno:
    enabled: {{ .Values.features.security }}
  mariadb-crds:
    enabled: {{ .Values.features.mariadb }}
  mariadb-operator:
    enabled: {{ .Values.features.mariadb }}
  postgres:
    enabled: {{ .Values.features.postgres }}
  reflector:
    enabled: {{ .Values.features.reflection }}
  reloader:
    enabled: {{ .Values.features.reloader }}
  sealed-secrets:
    enabled: {{ .Values.features.secrets }}
  trivy:
    enabled: {{ .Values.features.security }}
  volsync:
    enabled: {{ .Values.features.backup }}
{{- end -}}

{{/*
homelab.platformValues
Constructs the helm values YAML block for the platform (shared) sub-chart.
Maps feature flags to resource toggles and passes platform identity.
*/}}
{{- define "homelab.platformValues" -}}
global:
  project: shared
  domain: {{ .Values.platform.domain }}
  ip: {{ .Values.platform.ip }}
  {{- with .Values.platform.additionalDomains }}
  additionalDomains:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  email: {{ .Values.platform.email | default "" | quote }}
  timezone: {{ .Values.platform.timezone }}
  acme: {{ .Values.platform.acme }}
resources:
  ingressClass:
    enabled: {{ .Values.features.serviceMesh }}
  gateway:
    enabled: {{ .Values.features.serviceMesh }}
  gateways:
    public:
      enabled: {{ .Values.features.serviceMesh }}
    private:
      enabled: {{ .Values.features.serviceMesh }}
  certIssuer:
    enabled: {{ .Values.features.certificates }}
  certificate:
    enabled: {{ .Values.features.certificates }}
  storageClass:
    enabled: {{ .Values.features.storage }}
  pihole:
    enabled: {{ .Values.features.dns }}
  piholeDns:
    enabled: {{ .Values.features.dns }}
  postgresCluster:
    enabled: {{ .Values.features.postgres }}
  mariadb:
    enabled: {{ .Values.features.mariadb }}
  authentik:
    enabled: {{ .Values.features.auth }}
  meshPolicy:
    enabled: {{ .Values.features.meshPolicy }}
  backups:
    enabled: {{ .Values.features.backup }}
    nfs:
      server: {{ .Values.backup.nfs.server }}
      path: {{ .Values.backup.nfs.path }}
{{- end -}}

{{/*
homelab.monitoringValues
Constructs the helm values YAML block for the monitoring sub-chart.
*/}}
{{- define "homelab.monitoringValues" -}}
global:
  domain: {{ .Values.platform.domain }}
  ip: {{ .Values.platform.ip }}
  project: monitor
ntfy:
  url: {{ .Values.monitoring.ntfy.url }}
  topic: {{ .Values.monitoring.ntfy.topic }}
backups:
  nfs:
    server: {{ .Values.backup.nfs.server }}
    path: {{ .Values.backup.nfs.path }}
{{- end -}}

{{/*
homelab.syncPolicy
Standard sync policy used across all sub-chart Applications.
*/}}
{{- define "homelab.syncPolicy" -}}
automated:
  prune: true
  selfHeal: true
syncOptions:
  - ServerSideApply=true
  - ApplyOutOfSyncOnly=true
  - CreateNamespace=true
{{- end -}}

{{/*
homelab.mergeOverrides
Deep-merges user overrides into feature-derived values.
Usage: include "homelab.mergeOverrides" (dict "base" $baseYaml "overrides" .Values.overrides.X)
*/}}
{{- define "homelab.mergeOverrides" -}}
{{- $base := .base | fromYaml -}}
{{- $merged := mergeOverwrite $base .overrides -}}
{{- toYaml $merged -}}
{{- end -}}
