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
    {{- if $monitoring.values }}
    helm:
      values: |
        {{- $monitoring.values | toYaml | nindent 8 }}
    {{- end }}
  syncPolicy:
    {{- toYaml $syncPolicy | nindent 4 }}
  {{- if $monitoring.ignoreDifferences }}
  ignoreDifferences:
    {{- toYaml $monitoring.ignoreDifferences | nindent 4 }}
  {{- end }}
{{- end }}
{{- end }}
