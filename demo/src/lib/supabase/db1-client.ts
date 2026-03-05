import { createBrowserClient } from '@supabase/ssr'

export function createDb1Client() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_DB1_URL!,
    process.env.NEXT_PUBLIC_DB1_ANON_KEY!
  )
}
