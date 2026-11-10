// Sample file for issue #285. The PARENT directory is literally named "$post"
// (a TanStack Router / file-based-routing dynamic segment). The `$` is what
// trips vim.fn.expand(): it reads `$post` as the (undefined) env var `post` and
// substitutes the empty string, so the path the plugin checks no longer exists.
export default function Post() {
  return null;
}
