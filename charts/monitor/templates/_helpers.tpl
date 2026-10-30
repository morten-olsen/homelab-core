{{/*
Expand the name of the chart.
*/}}
{{- define "homelab-monitor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "homelab-monitor.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "homelab-monitor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "homelab-monitor.labels" -}}
helm.sh/chart: {{ include "homelab-monitor.chart" . }}
{{ include "homelab-monitor.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "homelab-monitor.selectorLabels" -}}
app.kubernetes.io/name: {{ include "homelab-monitor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Template for monitoring stack applications
*/}}
{{- define "homelab-monitor.monitoringApp" -}}
{{- $name := first . -}}
{{- $root := last . -}}
{{- $global := $root.Values.global -}}
{{- $project := default $global.project $root.Values.project -}}
{{- $monitoring := index $root.Values.monitoring $name -}}
{{- $syncPolicy := default $global.syncPolicy $monitoring.syncPolicy -}}
{{- $values := $monitoring.values -}}
{{- if and (eq $name "prometheus-operator") $root.Values.grafanaSso.enabled -}}
{{- $values = mergeOverwrite (deepCopy (default dict $monitoring.values)) (include "homelab-monitor.grafanaSsoValues" $root | fromYaml) -}}
{{- end -}}
{{- if $monitoring.enabled -}}
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ $name }}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    namespace: {{ $monitoring.namespace }}
    server: https://kubernetes.default.svc
  project: {{ $project }}
  source:
    repoURL: {{ $monitoring.repoURL }}
    targetRevision: {{ $monitoring.version }}
    {{- if $monitoring.chart }}
    chart: {{ $monitoring.chart }}
    {{- end }}
    {{- if $monitoring.path }}
    path: {{ $monitoring.path }}
    {{- end }}
    {{- if $values }}
    helm:
      values: |
        {{- $values | toYaml | nindent 8 }}
    {{- end }}
  syncPolicy:
    {{- toYaml $syncPolicy | nindent 4 }}
  {{- if $monitoring.ignoreDifferences }}
  ignoreDifferences:
    {{- toYaml $monitoring.ignoreDifferences | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}

{{- /*
Grafana values that add Authentik login (generic_oauth), merged over the
prometheus-operator values when grafanaSso.enabled. The client is the
AuthentikClient monitoring/grafana (application slug monitoring-grafana) from
grafana-sso.yaml. Authentik admits only the admin group; Grafana maps it to
Admin and, with role_attribute_strict, refuses anyone without a role. The
local admin login form stays as breakglass.
*/}}
{{- define "homelab-monitor.grafanaSsoValues" -}}
{{- $sso := .Values.grafanaSso -}}
{{- $domain := required "global.domain is required when grafanaSso is enabled" .Values.global.domain -}}
{{- $auth := printf "https://%s.%s/application/o" $sso.authSubdomain $domain -}}
grafana:
  envValueFrom:
    GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:
      secretKeyRef:
        name: grafana-oidc-credentials
        key: clientSecret
  grafana.ini:
    server:
      domain: {{ $sso.subdomain }}.{{ $domain }}
      root_url: https://{{ $sso.subdomain }}.{{ $domain }}/
    auth:
      disable_login_form: false
      signout_redirect_url: {{ $auth }}/monitoring-grafana/end-session/
    auth.generic_oauth:
      enabled: true
      name: Authentik
      client_id: grafana
      scopes: openid profile email
      use_pkce: true
      auth_url: {{ $auth }}/authorize/
      token_url: {{ $auth }}/token/
      api_url: {{ $auth }}/userinfo/
      login_attribute_path: preferred_username
      name_attribute_path: name
      email_attribute_path: email
      groups_attribute_path: groups
      role_attribute_path: contains(groups[*], '{{ $sso.adminGroup }}') && 'Admin'
      role_attribute_strict: true
      allow_sign_up: true
{{- end }}
