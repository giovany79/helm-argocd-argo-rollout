{{- define "rollouts-demo.name" -}}
{{- .Chart.Name }}
{{- end }}

{{- define "rollouts-demo.labels" -}}
app: {{ include "rollouts-demo.name" . }}
chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- define "rollouts-demo.selectorLabels" -}}
app: {{ include "rollouts-demo.name" . }}
{{- end }}
