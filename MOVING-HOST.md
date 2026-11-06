# Moving apt.tak3.io from GitHub Pages to S3 and CloudFront

The owner's steps. Customers' sources and the signing key do not change, and
Pages keeps serving until step 10. Up to step 9 no customer sees any of this.

`APT_PUBLISH_TO` says where a publish goes:

| Value | Reads from | Writes to | When |
|---|---|---|---|
| `pages` or unset | `gh-pages` | `gh-pages` | today, and after merging this |
| `both` | the bucket | the bucket and `gh-pages` | around the move |
| `s3` | the bucket | the bucket | after Pages is off |

There are no new secrets. AWS trusts GitHub's statement that a run is this
repository's `apt` or `apt-testing` environment, and gives it a role for an hour.

## Set up

**1. Merge the PR.** Nothing changes: `APT_PUBLISH_TO` is unset.

**2. An AWS account.** Create one for Imperium, with MFA on the root user and a
separate admin user for everyday use, and log the AWS CLI in as that user.

**3. Create the hosting**, from a checkout of `main`. The bill alert goes to the
address you give:

```bash
aws cloudformation deploy --region eu-central-1 --stack-name tak3-apt --template-file aws/hosting.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides AlertEmail=YOUR_ADDRESS
```

```bash
aws cloudformation describe-stacks --region eu-central-1 --stack-name tak3-apt --query 'Stacks[0].Outputs' --output table
```

If the bucket name is taken, add `BucketName=another-name` to the overrides. The
outputs give the values for the next step; `dxxxxxxxxxxxxx.cloudfront.net` below
stands for `CloudFrontAddress`.

**4. Tell the repository.** These are not secret:

```bash
gh variable set APT_S3_BUCKET --repo Imperium-Technologies-BV/tak3-apt --body tak3-apt-repository
```

```bash
gh variable set APT_S3_REGION --repo Imperium-Technologies-BV/tak3-apt --body eu-central-1
```

```bash
gh variable set APT_CDN_URL --repo Imperium-Technologies-BV/tak3-apt --body https://dxxxxxxxxxxxxx.cloudfront.net
```

```bash
gh variable set APT_AWS_ROLE --repo Imperium-Technologies-BV/tak3-apt --body THE_ROLE_OUTPUT
```

## Test on the new host

**5. Fill it and try it.** When the mirror run is green, from a machine with
docker and a checkout of this repository:

```bash
gh workflow run mirror.yml --repo Imperium-Technologies-BV/tak3-apt
```

```bash
./test-client.sh https://dxxxxxxxxxxxxx.cloudfront.net
```

That tries Ubuntu 22.04, 24.04 and Debian 12: the key is tak3's, `apt update`
passes on both suites, every package of this machine's architecture downloads
with its hash checked (a `~` version included), and the other architecture's are
there.

**6. Publish through both**, using the release candidate now in `testing`:

```bash
gh variable set APT_PUBLISH_TO --repo Imperium-Technologies-BV/tak3-apt --body both
```

```bash
gh workflow run publish.yml --repo Imperium-Technologies-BV/tak3-apt -f tag=v1.0.3-rc.1 -f source=Imperium-Technologies-BV/tak3-console
```

When it is green, the index must be fresh, with no wait. The first of these shows
a `Date:` from minutes ago, the second `Miss from cloudfront`:

```bash
curl -s https://dxxxxxxxxxxxxx.cloudfront.net/dists/testing/InRelease | grep '^Date:'
```

```bash
curl -sI https://dxxxxxxxxxxxxx.cloudfront.net/dists/testing/InRelease | grep -i '^x-cache'
```

The console's update check and `in-testing` both depend on this. Run
`test-client.sh` once more too.

## The certificate, then the name

**Before step 10, check the privacy page:** AWS will see customers' IP addresses
in place of GitHub. `tak3.io/privacy` and any list of processors may need to say so.

**7. Lower the TTL.** At Hetzner, set the `apt` CNAME's TTL to 300, and wait out
the old one (two hours), so every later change, and any way back, is quick.

**8. Make room for Amazon's certificate.** Amazon's authority will refuse to issue
one while the name is a CNAME to GitHub, because `github.io` publishes a CAA record
that does not list Amazon. So for this short while, replace the CNAME with Pages'
own addresses. `tak3.io` has no CAA record, so the check then passes. Pages answers
on them with its certificate (checked on 2026-11-06), and customers see no change.

```
apt.tak3.io  A  185.199.108.153
apt.tak3.io  A  185.199.109.153
apt.tak3.io  A  185.199.110.153
apt.tak3.io  A  185.199.111.153
```

Wait five minutes, then check Pages still answers:

```bash
./test-client.sh https://apt.tak3.io
```

**9. Get the certificate and add the name.** The certificate must be in `us-east-1`
whichever region the rest is in:

```bash
aws acm request-certificate --region us-east-1 --domain-name apt.tak3.io --validation-method DNS --query CertificateArn --output text
```

```bash
aws acm describe-certificate --region us-east-1 --certificate-arn THE_ARN --query 'Certificate.DomainValidationOptions[0].ResourceRecord'
```

At Hetzner, add the CNAME that prints, and **leave it there for good**: renewals
depend on it. Then wait for it, and add the certificate to CloudFront:

```bash
aws acm wait certificate-validated --region us-east-1 --certificate-arn THE_ARN
```

```bash
aws cloudformation deploy --region eu-central-1 --stack-name tak3-apt --template-file aws/hosting.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides CertificateArn=THE_ARN AlertEmail=YOUR_ADDRESS
```

Now try the customers' own address against CloudFront, certificate included, while
the name still points at Pages:

```bash
./test-client.sh https://apt.tak3.io dxxxxxxxxxxxxx.cloudfront.net
```

If the certificate fails with `CAA_ERROR`: check `dig CAA apt.tak3.io` shows nothing.
If that does not settle it, get a Let's Encrypt certificate over DNS (`certbot
certonly --manual --preferred-challenges dns -d apt.tak3.io`, which CAA allows even
under GitHub), import it with `aws acm import-certificate --region us-east-1`, use
that ARN above, and swap in an Amazon one after step 10. An imported one does not
renew itself.

**10. Move the name.** At Hetzner, replace the four A records with:

```
apt.tak3.io  CNAME  dxxxxxxxxxxxxx.cloudfront.net.
```

Both hosts hold the same files and answer with a good certificate, so a machine on
either side of the change is fine. Then:

```bash
dig +short CNAME apt.tak3.io
```

```bash
./test-client.sh https://apt.tak3.io
```

Check a real machine with `sudo apt update`, and the console's Settings › About.

**11. Stay on `both`** through at least one release candidate and one stable release.
The candidate's `in-testing` comment on the Next release issue is the proof that job
works on the new host. Pages stays ready to take over, but its certificate cannot
renew now the name has moved: it runs out on **2027-01-20**. Finish step 12 before
then, or a way back will have an HTTPS gap.

**12. Turn Pages off.** Keep the `gh-pages` branch, as the last copy outside AWS.

```bash
gh variable set APT_PUBLISH_TO --repo Imperium-Technologies-BV/tak3-apt --body s3
```

```bash
gh api -X DELETE repos/Imperium-Technologies-BV/tak3-apt/pages
```

## The way back

**Before step 10.** Customers are still on Pages. If AWS gets in the way of a release,
set `APT_PUBLISH_TO` to `pages`. Run the mirror again before going back to `both`. If
you stopped at step 8, put the CNAME back to `imperium-technologies-bv.github.io.`

**After step 10, Pages still on.** Point `apt` back at
`imperium-technologies-bv.github.io.`; at TTL 300 that takes about five minutes.
`gh-pages` is the same as the bucket, so customers lose nothing. Set `APT_PUBLISH_TO`
to `pages` if AWS itself is the trouble, then check with `./test-client.sh
https://apt.tak3.io`.

**After step 12.**

1. Set `APT_PUBLISH_TO` to `both`.
2. Publish the current release candidate as in step 6, which brings `gh-pages` level
   with the bucket. A Pages deploy of this size can time out; re-run it if so.
3. Settings › Pages: branch `gh-pages`, folder `/`, custom domain `apt.tak3.io`.
4. Point the CNAME back. HTTPS fails until GitHub has issued its certificate, which
   it can only do once the name points at it: expect minutes, possibly an hour, with
   `apt update` failing on customers' machines meanwhile.

**A bad or changed file in the bucket.** The bucket keeps old versions for 90 days, and
the publish role cannot erase them. Restore with `aws s3api list-object-versions` and
`aws s3api copy-object`, or publish again.

**Never delete the CloudFront distribution while the name still points at it:** another
AWS customer could then claim `apt.tak3.io`. Move the name first.

## What this does not fix

- During a publish, for a second or two, a machine running `apt update` can read a new
  `Packages` with the old `InRelease`, get a hash mismatch and keep its old lists. The
  next `apt update` is fine, and nothing wrong can be installed.
- The install steps fetch the key from `apt.tak3.io` without checking its fingerprint,
  so whoever controls the host could give new customers a different key. This is true on
  every host, Pages included.
- The signed indexes have no `Valid-Until`, so a host could keep serving an old one
  without apt noticing. This too is the same on every host.
