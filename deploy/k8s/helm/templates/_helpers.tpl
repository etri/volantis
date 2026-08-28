{{/*
Shared helpers.

Everything that has to agree in more than one place is derived here — the PLMN
label value, the PLMN config object, the image name — so that the pod labels, a
service definition's selectors and an NF's own config cannot disagree about
what network this is.
*/}}

{{/* The PLMN as a label value: mcc-mnc. */}}
{{- define "volantis.plmnId" -}}
{{ .Values.plmn.mcc }}-{{ .Values.plmn.mnc }}
{{- end -}}

{{/* The plmnId object every NF config carries. */}}
{{- define "volantis.plmnObject" -}}
{{- dict "mcc" .Values.plmn.mcc "mnc" .Values.plmn.mnc -}}
{{- end -}}

{{/* An image name. Takes {root, app}. */}}
{{- define "volantis.image" -}}
{{ .root.Values.image.prefix }}-{{ .app }}:{{ .root.Values.image.tag }}
{{- end -}}

{{/* A slice's label value: <sst>-<sd>. Takes the slice. */}}
{{- define "volantis.sliceKey" -}}
{{ printf "%d-%s" (int .sst) .sd }}
{{- end -}}

{{/*
Configuration errors that Kubernetes would accept and the deployment would not.
Each of these otherwise shows up as a network function that starts, registers,
and never becomes selectable — or as a process that exits at startup — which is
a much longer way round to the same information.
*/}}
{{- define "volantis.validate" -}}

{{/* Values that must be strings and would otherwise be read as numbers. YAML
     turns an unquoted 001 into 1 and an unquoted 010203 into 10203, and both
     go on to produce a label or a config field that is quietly wrong rather
     than an error anyone sees. */}}
{{- if not (kindIs "string" .Values.plmn.mcc) }}
  {{- fail (printf "plmn.mcc %v must be quoted: an unquoted 001 is read as the number 1" .Values.plmn.mcc) }}
{{- end }}
{{- if not (kindIs "string" .Values.plmn.mnc) }}
  {{- fail (printf "plmn.mnc %v must be quoted: an unquoted 01 is read as the number 1" .Values.plmn.mnc) }}
{{- end }}
{{- if .Values.pran.enabled }}
  {{- if not (kindIs "string" .Values.pran.tac) }}
    {{- fail (printf "pran.tac %v must be quoted: an unquoted 001 is read as the number 1" .Values.pran.tac) }}
  {{- end }}
{{- end }}
{{- if .Values.smf.enabled }}
  {{- range .Values.smf.slices }}
    {{- if not (kindIs "string" .sd) }}
      {{- fail (printf "smf.slices: sd %v must be quoted: an unquoted 010203 is read as a number and the slice label comes out wrong" .sd) }}
    {{- end }}
    {{- if kindIs "string" .sst }}
      {{- fail (printf "smf.slices: sst %q must not be quoted: it is a number in the NF's configuration" .sst) }}
    {{- end }}
  {{- end }}
{{- end }}
{{- if .Values.amf.enabled }}
  {{- range .Values.amf.sets }}
    {{- if not (kindIs "string" .id) }}
      {{- fail (printf "amf.sets: id %v must be quoted: it is a <region>-<set> string, not a number" .id) }}
    {{- end }}
  {{- end }}
{{- end }}
{{- if .Values.nsm.enabled }}
  {{- range .Values.nsm.config.slices }}
    {{- if not (kindIs "string" .id.sd) }}
      {{- fail (printf "nsm.config.slices: sd %v must be quoted" .id.sd) }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if .Values.gateway.enabled }}
  {{- if not .Values.gateway.id }}
    {{- fail "gateway.id must be set: agents cache it as the GwId of every endpoint behind this gateway" }}
  {{- end }}
  {{- if and (not .Values.gateway.advertise.local) (not .Values.gateway.advertise.external) }}
    {{- fail "gateway.advertise: set local, external or both — a gateway that advertises nothing exits at startup" }}
  {{- end }}
  {{- if .Values.controller.enabled }}
    {{- if not (has .Values.gateway.id .Values.controller.gateways) }}
      {{- fail (printf "gateway.id %q is not in controller.gateways %v — the controller refuses a gateway that is not on the allow-list" .Values.gateway.id .Values.controller.gateways) }}
    {{- end }}
  {{- end }}
{{- end }}

{{- if .Values.nsm.enabled }}
  {{- if not .Values.nsm.suciProfiles }}
    {{- fail "nsm.suciProfiles must not be empty: a UDM with no profile fails authentication for every UE and never becomes ready" }}
  {{- end }}
  {{- range .Values.nsm.suciProfiles }}
    {{- if kindIs "string" .protectionScheme }}
      {{- fail (printf "nsm.suciProfiles: protectionScheme %q is quoted — NSM types it int16 and exits at startup on a string" .protectionScheme) }}
    {{- end }}
  {{- end }}

  {{/* A set with no slices, or a slice no set serves, is a deployment that
       registers and then cannot carry a UE. Only checkable when NSM is part of
       the same release; in a multi-cloud edge it is not. */}}
  {{- $sets := list }}
  {{- range .Values.nsm.config.amfSets }}{{ $sets = append $sets .setId }}{{ end }}
  {{- if .Values.amf.enabled }}
    {{- range .Values.amf.sets }}
      {{- if not (has .id $sets) }}
        {{- fail (printf "amf.sets: set %q has no entry in nsm.config.amfSets %v — it would serve no slice" .id $sets) }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if .Values.pran.enabled }}
    {{- $region := printf "%d-" (int .Values.pran.amfRegion) }}
    {{- $inRegion := false }}
    {{- range $sets }}{{ if hasPrefix $region . }}{{ $inRegion = true }}{{ end }}{{ end }}
    {{- if not $inRegion }}
      {{- fail (printf "pran.amfRegion %v matches no AMF set in nsm.config.amfSets %v — PRAN refuses to open its SCTP listener" .Values.pran.amfRegion $sets) }}
    {{- end }}
    {{- $trans := .Values.nsm.config.transportNetworks }}
    {{- range .Values.pran.transportNetworks }}
      {{- if not (has . $trans) }}
        {{- fail (printf "pran.transportNetworks: %q is not declared in nsm.config.transportNetworks %v" . $trans) }}
      {{- end }}
    {{- end }}
  {{- end }}
  {{- if .Values.smf.enabled }}
    {{- $slices := list }}
    {{- range .Values.nsm.config.slices }}{{ $slices = append $slices (include "volantis.sliceKey" .id) }}{{ end }}
    {{- range .Values.smf.slices }}
      {{- $k := include "volantis.sliceKey" . }}
      {{- if not (has $k $slices) }}
        {{- fail (printf "smf.slices: slice %q is not declared in nsm.config.slices %v" $k $slices) }}
      {{- end }}
    {{- end }}
  {{- end }}
{{- end }}

{{- end -}}

{{/*
One service definition: a headless Service whose selector set is the service
identity. Takes {ns, name, selectors, port}.
*/}}
{{- define "volantis.definition" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    type: network-function
{{- with .annotation }}
  annotations:
    mesh.volantis.io/definition: |
{{ . | indent 6 }}
{{- end }}
spec:
  clusterIP: None
  selector:
{{ toYaml .selectors | indent 4 }}
  ports:
    - name: sbi
      protocol: TCP
      port: {{ .port }}
{{- end -}}


{{/*
The locality-routing body: prefer a producer in the consumer's own cloud, spill
to another when there is none.

`fallthrough: true` is what makes it a preference rather than a constraint —
drop it and a cloud with no selectable producer stops serving instead of
reaching across. There is deliberately no catch-all route: the service-wide
balancer already is one, so N clouds cost N routes.

The two sides of a route match **different label sets**, which is why one
`routing.key` renders under two different names:

  * a group selects on `_gw-<key>`, which the gateway stamps on every endpoint
    it registers — producer-side, authoritative, and set once per cloud as
    `gateway.labels`;
  * a route's `from` matches the consumer's own view of itself, which is its
    configured `meshLabels` and not its pod labels, which it never sees.

Get one of the two wrong and the failure is quiet: a group that selects nothing
makes the route fall through, a `from` that matches nothing makes it never
apply. Both leave the service working, just not locally.
*/}}
{{- define "volantis.routes" -}}
{{- $key := .Values.routing.key -}}
{{- $groups := dict -}}
{{- $routes := list -}}
{{- range .Values.routing.clouds -}}
{{- $_ := set $groups . (dict "selectors" (dict (printf "_gw-%s" $key) .)) -}}
{{- $routes = append $routes (dict "from" (dict $key .) "fallthrough" true
      "destinations" (list (dict "group" . "weight" 100))) -}}
{{- end -}}
{{- dict "stateful" true "groups" $groups "routes" $routes | toPrettyJson -}}
{{- end -}}
