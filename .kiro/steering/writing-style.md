---
inclusion: always
---

# Writing Style and Documentation Guide

This guide shapes how every explanation, comment, and piece of documentation in this
repository should be written. The goal is simple: anyone should be able to read what we
produce and understand it without having to ask a more senior person first.

## Who you are writing for

Assume the reader is a **junior administrator** with limited experience and limited
context about this project. They are smart and capable, but they may be new to the tools,
the cloud platforms, or the way this system is put together. Write so that this person can
follow along and succeed on their own.

A good test: if a brand-new team member read this on their first day, would they understand
it and know what to do next? If not, add more context or simplify the language.

## How to write

### Keep it human and conversational

- Write the way you would explain something to a colleague sitting next to you.
- Use plain, friendly language. Short sentences are easier to follow than long ones.
- It is fine to address the reader directly as "you."
- Explain the *why* behind something, not just the *what*. Context helps people remember.

### Avoid jargon (and explain it when you can't)

- Avoid technical jargon, acronyms, and insider shorthand whenever a plainer word will do.
- When a technical term is genuinely necessary, give a short, plain-language explanation the
  first time it appears. For example:
  > We store the state in an **S3 bucket** (an Amazon storage container for files).
- Spell out an acronym the first time you use it, then the short form is fine after that.

### When the reader needs to do something, give clear steps

If an explanation requires the reader to take action, provide clear, concise, numbered
step-by-step instructions. Each step should be one action, in the order it must happen.
Prefer this:

1. Open a terminal in the project folder.
2. Run `npm install` to download the required packages.
3. Wait for it to finish — you will see a success message when it is done.

over a single paragraph that buries the steps in prose. If a step can fail, tell the reader
what a successful result looks like so they know whether to continue.

### Always point to supporting resources

Whenever a helpful link, official documentation page, or supporting resource exists, include
it. This lets the reader go deeper or confirm a detail without guessing. Use descriptive link
text that says where the link goes, like
[the Terraform CLI documentation](https://developer.hashicorp.com/terraform/cli), rather than
a bare URL or a vague "click here."

## Quick checklist before you publish

- [ ] Would a junior administrator understand this without extra help?
- [ ] Is the tone conversational and friendly, not stiff or overly formal?
- [ ] Did I avoid jargon, or clearly explain any term I had to use?
- [ ] If the reader must act, are there clear numbered steps?
- [ ] Did I include relevant links, docs, or resources where they exist?
