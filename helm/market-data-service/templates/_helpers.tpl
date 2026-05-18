{{/*
Expand the name of the chart.
*/}}
{{- define "market-data-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "market-data-service.fullname" -}}
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
{{- define "market-data-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "market-data-service.labels" -}}
helm.sh/chart: {{ include "market-data-service.chart" . }}
{{ include "market-data-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: mini-nasdaq-gitops
{{- end }}

{{/*
Selector labels
*/}}
{{- define "market-data-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "market-data-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app: {{ include "market-data-service.name" . }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "market-data-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "market-data-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
