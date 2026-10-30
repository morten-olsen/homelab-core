{{- define "homelab-core.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "homelab-core.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "homelab-core.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "homelab-core.labels" -}}
helm.sh/chart: {{ include "homelab-core.chart" . }}
{{ include "homelab-core.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "homelab-core.selectorLabels" -}}
app.kubernetes.io/name: {{ include "homelab-core.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- /* ArgoCD values that delegate login to Authentik. Merged over
       operators.argocd.values when argocdSso.enabled. The client itself is the
       shared chart's AuthentikClient argocd/argocd (application slug
       argocd-argocd); only argocdSso.adminGroup gets in, as role:admin. The
       built-in admin account stays enabled as breakglass. */ -}}
{{- define "homelab-core.argocdSsoValues" -}}
{{- $sso := .Values.argocdSso -}}
{{- $domain := required "global.domain is required when argocdSso is enabled" .Values.global.domain -}}
configs:
  cm:
    url: https://{{ $sso.subdomain }}.{{ $domain }}
    admin.enabled: true
    oidc.config: |
      name: Authentik
      issuer: https://{{ $sso.authSubdomain }}.{{ $domain }}/application/o/argocd-argocd/
      clientID: argocd
      enablePKCEAuthentication: true
      requestedScopes: [openid, profile, email]
  rbac:
    policy.default: ""
    policy.csv: |
      g, {{ $sso.adminGroup }}, role:admin
    scopes: "[groups]"
{{- end }}
