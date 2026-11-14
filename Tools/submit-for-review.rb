#!/usr/bin/env ruby
# Sends an uploaded build to App Review, using the App Store Connect API.
#
#   Tools/submit-for-review.rb <version> <build>
#
# The release workflow runs this after every upload. It only submits when all of these hold:
#   - docs/appstore/whats-new/<version>.txt exists (writing it is the go-ahead for that version);
#   - that version hasn't been sent to Apple already and isn't live;
#   - no other version is waiting on Apple (it never pulls anything out of review).
# Otherwise it says why and exits 0, and the build stays a TestFlight build.
#
# On a submit it creates the version (or renames the one still being prepared), attaches the
# build, fills in What's New for every language on the listing, sets it to release as soon as
# it's approved, and submits. Screenshots and the rest of the listing carry over from the
# previous version; change those in App Store Connect.
#
# Needs ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) in the environment.
# `--self-test` checks the decision rules and the token signing without touching Apple.
require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

BUNDLE_ID = 'com.nikhilmath.HarleyChipTracker'
API = 'https://api.appstoreconnect.apple.com'

# Being prepared: safe to fill in and submit.
EDITABLE = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED].freeze
# Apple sent it back: a person has to read why first.
REJECTED = %w[REJECTED METADATA_REJECTED INVALID_BINARY].freeze
# No longer in play.
FINISHED = %w[READY_FOR_SALE REPLACED_WITH_NEW_VERSION DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE].freeze

# What to do, given every version of the app on App Store Connect ({id:, version:, state:}).
# Returns [:skip, why], [:create] or [:use, id, rename?].
def decide(versions, version)
  same = versions.find { |v| v[:version] == version }
  if same && FINISHED.include?(same[:state])
    return [:skip, "Version #{version} is already on the App Store. Raise the version number to submit a new one."]
  end
  if (sent_back = versions.find { |v| REJECTED.include?(v[:state]) })
    return [:skip, "Apple sent version #{sent_back[:version]} back (#{sent_back[:state]}). Sort that out in App Store Connect first."]
  end
  waiting = versions.find { |v| !EDITABLE.include?(v[:state]) && !FINISHED.include?(v[:state]) }
  if waiting && waiting[:version] == version
    return [:skip, "Version #{version} is already with Apple (#{waiting[:state]}). This build is on TestFlight only; " \
                   "to swap it in, remove the version from review in App Store Connect and run the workflow again."]
  end
  if waiting
    return [:skip, "Version #{waiting[:version]} is still with Apple (#{waiting[:state]}), and only one version can be. " \
                   "The daily Submit waiting version check sends #{version} once it's released."]
  end
  draft = versions.find { |v| EDITABLE.include?(v[:state]) }
  draft ? [:use, draft[:id], draft[:version] != version] : [:create]
end

def token(key_id, issuer, pem)
  segment = ->(hash) { Base64.urlsafe_encode64(JSON.generate(hash), padding: false) }
  now = Time.now.to_i
  unsigned = segment.call(alg: 'ES256', kid: key_id, typ: 'JWT') + '.' +
             segment.call(iss: issuer, iat: now, exp: now + 600, aud: 'appstoreconnect-v1')
  der = OpenSSL::PKey.read(pem).sign(OpenSSL::Digest.new('SHA256'), unsigned)
  # A JWT wants the two 32-byte numbers side by side, not OpenSSL's DER wrapping.
  raw = OpenSSL::ASN1.decode(der).value.map { |n| n.value.to_s(2).rjust(32, "\x00".b) }.join
  unsigned + '.' + Base64.urlsafe_encode64(raw, padding: false)
end

class Connect
  class Failed < StandardError; end

  def initialize(key_id, issuer, pem)
    @key_id, @issuer, @pem = key_id, issuer, pem
  end

  def get(path)
    call(Net::HTTP::Get, path)
  end

  # `allow` lists status codes to shrug off (returns nil for those).
  def post(path, body, allow = [])
    call(Net::HTTP::Post, path, body, allow)
  end

  def patch(path, body)
    call(Net::HTTP::Patch, path, body)
  end

  private

  def call(verb, path, body = nil, allow = [])
    uri = URI(API + path)
    request = verb.new(uri)
    request['Authorization'] = "Bearer #{token(@key_id, @issuer, @pem)}"
    if body
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
    end
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |http| http.request(request) }
    code = response.code.to_i
    return nil if allow.include?(code)
    unless (200..299).cover?(code)
      details = begin
        JSON.parse(response.body)['errors'].map { |e| e['detail'] || e['title'] }.join(' ')
      rescue StandardError
        response.body.to_s[0, 300]
      end
      raise Failed, "#{verb::METHOD} #{path.split('?').first} failed (#{code}): #{details}"
    end
    response.body.to_s.empty? ? {} : JSON.parse(response.body)
  end
end

def notice(text)
  puts(ENV['GITHUB_ACTIONS'] ? "::notice title=App Review::#{text}" : text)
end

def self_test
  check = ->(expected, versions, label) do
    got = decide(versions, '1.5')
    abort "FAILED #{label}: #{got.inspect}" unless got.first(expected.size) == expected
  end
  v = ->(version, state, id = 'x') { { id: id, version: version, state: state } }
  check.call([:create], [v['1.4', 'READY_FOR_SALE']], 'new version')
  check.call([:create], [], 'nothing yet')
  check.call([:use, 'd', false], [v['1.5', 'PREPARE_FOR_SUBMISSION', 'd'], v['1.4', 'READY_FOR_SALE']], 'draft of this version')
  check.call([:use, 'd', true], [v['1.4.1', 'PREPARE_FOR_SUBMISSION', 'd']], 'draft of another version')
  check.call([:use, 'd', false], [v['1.5', 'DEVELOPER_REJECTED', 'd']], 'pulled from review')
  check.call([:skip], [v['1.5', 'READY_FOR_SALE']], 'already live')
  check.call([:skip], [v['1.5', 'WAITING_FOR_REVIEW']], 'already submitted')
  check.call([:skip], [v['1.4', 'IN_REVIEW'], v['1.3', 'READY_FOR_SALE']], 'another in review')
  check.call([:skip], [v['1.4', 'PENDING_DEVELOPER_RELEASE']], 'another approved, not released')
  check.call([:skip], [v['1.4', 'REJECTED']], 'rejected')

  key = OpenSSL::PKey::EC.generate('prime256v1')
  header, payload, signature = token('KEYID', 'ISSUER', key.to_pem).split('.')
  raw = Base64.urlsafe_decode64(signature)
  abort 'FAILED token: signature is not 64 bytes' unless raw.bytesize == 64
  der = OpenSSL::ASN1::Sequence([raw[0, 32], raw[32, 32]].map { |n| OpenSSL::ASN1::Integer(OpenSSL::BN.new(n, 2)) }).to_der
  abort 'FAILED token: signature does not verify' unless key.verify(OpenSSL::Digest.new('SHA256'), der, "#{header}.#{payload}")
  abort 'FAILED token: wrong audience' unless JSON.parse(Base64.urlsafe_decode64(payload))['aud'] == 'appstoreconnect-v1'
  puts 'Self-test passed.'
end

# In-app purchases (the tip jar) that are filled in but not yet sent go to review with this
# version: Apple reviews an app's first purchases only together with an app version.
# One that's missing details (price, screenshot) is skipped and named, never blocking the app.
def submit_ready_in_app_purchases(connect, app_id)
  purchases = connect.get("/v1/apps/#{app_id}/inAppPurchasesV2?limit=50")['data']
  purchases.each do |purchase|
    name = "#{purchase['attributes']['name']} (#{purchase['attributes']['productId']})"
    case purchase['attributes']['state']
    when 'READY_TO_SUBMIT'
      connect.post('/v1/inAppPurchaseSubmissions', { data: {
        type: 'inAppPurchaseSubmissions',
        relationships: { inAppPurchaseV2: { data: { type: 'inAppPurchases', id: purchase['id'] } } }
      } }, [409])
      puts "Sending in-app purchase #{name} with this version."
    when 'MISSING_METADATA'
      notice("In-app purchase #{name} is missing details in App Store Connect, so it wasn't sent.")
    end
  end
rescue Connect::Failed => error
  notice("Couldn't send in-app purchases: #{error.message}")
end

def main(version, build)
  notes_file = File.expand_path("../docs/appstore/whats-new/#{version}.txt", __dir__)
  unless File.exist?(notes_file)
    return notice("Not submitted: there's no docs/appstore/whats-new/#{version}.txt. Add it to send #{version} to App Review.")
  end
  whats_new = File.read(notes_file).strip
  abort "#{notes_file} is empty." if whats_new.empty?
  abort "#{notes_file} is over Apple's 4,000 character limit." if whats_new.length > 4000

  connect = Connect.new(ENV.fetch('ASC_KEY_ID'), ENV.fetch('ASC_ISSUER_ID'), File.read(ENV.fetch('ASC_KEY_PATH')))
  app = connect.get("/v1/apps?filter[bundleId]=#{BUNDLE_ID}")['data'].find { |a| a['attributes']['bundleId'] == BUNDLE_ID }
  abort "No app with bundle ID #{BUNDLE_ID} on this App Store Connect account." unless app
  app_id = app['id']

  versions = connect.get("/v1/apps/#{app_id}/appStoreVersions?filter[platform]=IOS&limit=50")['data'].map do |v|
    { id: v['id'], version: v['attributes']['versionString'], state: v['attributes']['appStoreState'] }
  end
  action, version_id, rename = decide(versions, version)
  return notice("Not submitted: #{version_id}") if action == :skip

  # Apple takes a while to process an upload; a build can't be attached until it has.
  build_id = nil
  deadline = Time.now + 40 * 60
  loop do
    found = connect.get("/v1/builds?filter[app]=#{app_id}&filter[version]=#{build}" \
                        "&filter[preReleaseVersion.version]=#{version}&limit=1")['data'].first
    state = found && found['attributes']['processingState']
    if state == 'VALID'
      build_id = found['id']
      break
    end
    abort "Apple couldn't process build #{build} (#{state}). Check your email from App Store Connect." if %w[FAILED INVALID].include?(state)
    abort "Build #{build} was still processing after 40 minutes. Run the workflow again later." if Time.now > deadline
    puts "Waiting for Apple to process build #{build}…"
    sleep 30
  end

  attributes = { versionString: version, releaseType: 'AFTER_APPROVAL' }
  if action == :create
    version_id = connect.post('/v1/appStoreVersions', { data: {
      type: 'appStoreVersions', attributes: attributes.merge(platform: 'IOS'),
      relationships: { app: { data: { type: 'apps', id: app_id } } }
    } })['data']['id']
    puts "Created version #{version}."
  else
    connect.patch("/v1/appStoreVersions/#{version_id}", { data: { type: 'appStoreVersions', id: version_id, attributes: attributes } })
    puts(rename ? "Renamed the version being prepared to #{version}." : "Using the #{version} already being prepared.")
  end

  connect.patch("/v1/appStoreVersions/#{version_id}/relationships/build", { data: { type: 'builds', id: build_id } })
  connect.get("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations")['data'].each do |localization|
    connect.patch("/v1/appStoreVersionLocalizations/#{localization['id']}", { data: {
      type: 'appStoreVersionLocalizations', id: localization['id'], attributes: { whatsNew: whats_new }
    } })
  end
  puts "Attached build #{build} and filled in What's New."

  submit_ready_in_app_purchases(connect, app_id)

  open = connect.get("/v1/reviewSubmissions?filter[app]=#{app_id}&filter[platform]=IOS&filter[state]=READY_FOR_REVIEW")['data'].first
  submission_id = open ? open['id'] : connect.post('/v1/reviewSubmissions', { data: {
    type: 'reviewSubmissions', attributes: { platform: 'IOS' },
    relationships: { app: { data: { type: 'apps', id: app_id } } }
  } })['data']['id']
  # 409: the version is already in a submission left open earlier.
  connect.post('/v1/reviewSubmissionItems', { data: {
    type: 'reviewSubmissionItems',
    relationships: { reviewSubmission: { data: { type: 'reviewSubmissions', id: submission_id } },
                     appStoreVersion: { data: { type: 'appStoreVersions', id: version_id } } }
  } }, open ? [409] : [])
  connect.patch("/v1/reviewSubmissions/#{submission_id}", { data: {
    type: 'reviewSubmissions', id: submission_id, attributes: { submitted: true }
  } })
  notice("Submitted Chip Chaser #{version} (build #{build}) to App Review. It releases by itself once approved.")
rescue Connect::Failed => error
  abort "Not submitted. #{error.message}"
end

if ARGV == ['--self-test']
  self_test
elsif ARGV.size == 2
  main(*ARGV)
else
  abort 'usage: Tools/submit-for-review.rb <version> <build>'
end
