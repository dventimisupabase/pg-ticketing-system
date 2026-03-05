export default function AboutPage() {
  return (
    <div className="mx-auto max-w-2xl">
      <h1 className="mb-4 text-3xl font-bold">About</h1>

      <div className="space-y-4 text-zinc-300 leading-relaxed">
        <p>
          This is a demo ticket marketplace built on{' '}
          <a href="https://supabase.com" className="text-cyan-400 hover:underline" target="_blank" rel="noopener noreferrer">
            Supabase
          </a>
          , demonstrating the{' '}
          <strong className="text-white">Burst-to-Queue Ledger</strong>{' '}
          architecture for high-concurrency ticket sales.
        </p>

        <p>
          The system handles up to <strong className="text-white">1,000 claims per second</strong>{' '}
          with zero errors — enough to sell out a 50,000-seat stadium in under a minute.
        </p>

        <p>
          Read the full technical explainer:{' '}
          <a href="https://dventimisupabase.github.io/pg-ticketing-system/" className="text-cyan-400 hover:underline" target="_blank" rel="noopener noreferrer">
            Burst-to-Queue Ledger
          </a>
        </p>
      </div>
    </div>
  )
}
