{{- define "name" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 }}
{{- else }}
{{- .Chart.Name | trunc 63 }}
{{- end }}
{{- end }}
