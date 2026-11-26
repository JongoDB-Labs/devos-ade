# shellcheck shell=bash
# _owui_models_wanted as it was at v0.68.6 (aa9321ba), before JON-972 built the list in one pass, renamed
# old_owui_models_wanted: tests/test_owui_wanted_identity.sh runs it beside the new one and compares the lines byte for
# byte. It calls the live per-model helpers (price_label, owui_model_name, display_name, owui_tags_json, icon_url), so
# the one-pass list must keep saying what they say. Do not edit.
old_owui_models_wanted() {
  local en name mode aliases a hidden wish list price
  local -a alias_list
  en="$(_enabled_or_all)"
  list=",$(get_env MODELS_HIDDEN),"
  while IFS=$'\t' read -r name mode _ aliases _ <&3; do
    is_enabled "$name" "$en" || continue
    price="$(price_label "$name")"
    if [ "$mode" = chat ]; then
      hidden=false; wish=false; case "$list" in *",$name,"*) wish=true ;; esac
    else hidden=true; wish=-; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$(owui_model_name "$name" "$mode")" "$(display_name "$name")" \
      "AWS Bedrock · $price" "$(owui_tags_json "$name" "$mode")" "$hidden" "$(icon_url "$name")" "$wish"
    [ "$aliases" != - ] && [ -n "$aliases" ] || continue
    IFS=, read -r -a alias_list <<< "$aliases"
    for a in ${alias_list[@]+"${alias_list[@]}"}; do
      [ -n "$a" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$a" "$a" "AWS Bedrock · alias of $name · $price" '[{"name":"Bedrock"}]' true '' -
    done
  done 3< <(catalog_rows)
}
